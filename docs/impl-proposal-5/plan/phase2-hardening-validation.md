# Phase 2 hardening: scheduling, receive isolation and failure histories

Date: 2026-09-16. This supplements [the original Runtime report](phase2-local-runtime-validation.md)
and [current-basis optimization](current-basis-validation.md). The implementation
still supports ordinary Create/Put/Delete histories, empty host settings and raw
current cells. General conflict/undo reduction and the provider adapter remain
later increments.

## Implemented behavior

### Scheduling and ownership

Eligible current-state saves keep the existing short validation path. Other
ordinary histories use `DatabaseLane.historyWork`: a dedicated serial Dispatch
worker runs the same complete `OrdinaryHistoryV1` validator. Its iterative stack,
visited set and in-progress cycle evidence survive between reads. Each historical
lookup gets its own turn on the database writer; local saves can run between
those turns. The worker never exposes the SQLite handle or occupies Swift's
cooperative executor with blocking I/O.

Each lookup checks physical ownership, known damage and the captured accepted
prefix. The file-private `CheckedHistoryWork` is issued only after complete
validation, binds exact bytes/locator/payload/prefix, and is consumed in a new
transaction that rechecks ownership/header/prefix before acceptance. Changed
history restarts the check. Two failed captures retain the admitted local capture
with `busy`; an owned receive now continues automatically after active saves settle.
The [resumption/rejection follow-up](validation-resumption-results.md) qualifies
that scheduling and rejection-failure behavior separately from this earlier run.

Ready draining processes one candidate per writer turn; each complete accepted
batch advances current rows, authoring context and coverage in its own transaction.
The next batch yields the writer again. An editable reopen still requires the
whole currently required suffix and ready work to be settled. Quiesce waits for
owned receive/save work before releasing the database lease.

Returning open repairs an invalid derived view **before** ready-history draining
can materialize another batch. The combined test (corrupt current cell plus a
durably queued valid child) exposed an ordering regression from per-candidate
catch-up; restoring the old order is now an assertion-targeted mutation.

These are work-unit bounds, not a hard real-time guarantee. A bounded envelope
decode, SQLite call or indivisible action transaction can exceed 10 ms. Always
yielding between reads/candidates is finer grained than the scheduling table's
256-record threshold. There is no durable traversal-cache schema: restart uses
the existing durable ready work, and revalidates an unfinished candidate. Large
initial bootstrap/rebuild validation remains synchronous worker code and requires
its separate large-import qualification before general application integration.

The [rough scheduling benchmark](history-read-scheduling-benchmark.md) measures
the throughput cost and a small-batch read-replay estimate. It leaves the
production scheduling and all acceptance checks unchanged.

### Durable receive isolation

Supported, verified outer Changes envelopes are retained before payload decoding.
Definite malformed/unsupported payloads and invalid ordinary actions receive a
`rejected_objects` row: exact object ID, validator version 1, stable reason.
In the same transaction, their ready entry and outgoing dependency waits are
removed. The exact envelope remains in `objects`; accepted history and its pin
are untouched. Other ready work continues.

A repeated exact hash checks the saved classification before decoding again and
checks byte equality. Reopen retains the result. New bytes have a different hash;
a future validator version must explicitly reconsider unsupported candidates.
Missing dependencies stay parked. I/O/busy/ownership/key-derivation failures and
accepted-history damage remain distinct errors, rather than permanent rejection.
Failure to commit a rejection leaves its durable candidate available for retry.
Unknown outer-envelope kinds/versions still return unsupported before admission;
provider-level preservation of arbitrary raw foreign input belongs to the later
provider adapter.

The additional private table is receive evidence, not a validation cache for
ordinary saves. No wire format, shared metadata, public receipt constructor,
causal merge rule or user-visible conflict policy changes.

## Tests and challenges

| Obligation | Production-path evidence |
| --- | --- |
| Background work yields to saving | Hold the real history worker after a divergent receive captures its prefix; commit a newer local save; release and require complete revalidation and both expected results. Both profiles. |
| Stale checked history is rejected | A matching prefix succeeds; a same-type wrong prefix fails at the actual historical-read consumer. Mutation removes that check. |
| Complete bounded catch-up | Four accepted/unmaterialized batches advance exactly one prefix and independently expected body per call, then survive reopening. Mutation advances all batches in one turn. |
| Derived damage plus ready work | Reopen rebuilds damaged current cells, then validates/applies a queued child and publishes both independently expected notes. Mutation drains before repairing the view. |
| Rejected child cannot poison the queue | Park an invalid child before its valid parent; reopen, deliver parent, preserve exact bad bytes/reason, then accept its valid sibling. Repeat bad input after reopen. Mutation drops the rejection row. |
| Malformed payload isolation | Authenticate a truncated payload, retain/reject it, reopen, repeat it, and save a valid ordinary edit. |
| Wrong incoming address | A declared dependency with the right hash and wrong writer address is rejected as invalid input; its valid companion accepts. This caught and corrected an old `integrity` classification that could stop unrelated ready work. |
| Error-category separation | Every stable reason round-trips; storage, ownership, incomplete accepted history, missing dependency and key-derivation errors are excluded. |
| Failure combinations | `test-storage-generated.py`: four seeded command/delivery permutations per profile, repeated deliveries and recovery failures; inspect exact history with the independent Node inspector. |
| Failed damage recording | Corrupt positively identified accepted history, fail the marker write three times with EIO or ENOSPC, require blocked publication and absent marker, then retry and require a durable marker and refusal on fresh reopen. |

The generated campaign issues real Put/Create/Delete commands to a source store,
then sends the resulting exact envelopes to an independent copied-bootstrap
receiver in shuffled order. Its command oracle tracks expected birth-to-body associations independently
of the Swift reducer. Five ordinary actions produce six accepted batches including
bootstrap, despite duplicate deliveries. Fresh children receive only normal
selection/unlock data and the surviving store; the parent keeps the oracle.

Six reached fault classes are required: before commit, after commit, a later
commit, current-view update, failed write (EIO), and failed sync (ENOSPC). Selected
schedules interrupt recovery repeatedly before normal retry. These are termination
and injected I/O tests; neither they nor subsequent corruption simulate physical
power removal. The accepted-history damage marker retains its documented limit:
if the marker cannot commit and the process is lost, an unrecorded observation may
be lost. Live failure remains fail-closed; healthy launch does not gain a mandatory
full-history scan.

Compiler probes add both ordinary-client and same-module attempts to construct
`CheckedHistoryWork`, alongside its real issuer/consumer tests. Runtime mutations
now include lost rejection evidence, ignored history prefixes and unbounded
materialization, as well as the existing acknowledgment, dependency, retention,
completion, wakeup, context and current-basis challenges. Each must fail its named
runtime assertion after a discovered passing baseline.

## Qualification commands

```sh
python3 tools/test-storage-phase2.py --configuration debug
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-runtime-mutations.py --configuration debug
python3 tools/test-storage-runtime-mutations.py --configuration release

NV_SQLCIPHER_DEST="$PWD/NVStorage/.deps/sqlcipher-asan" \
NV_SQLCIPHER_SANITIZERS=address tools/build-storage-deps.sh
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan
```

The sanitizer archive uses the same pinned source and cipher configuration in a
separate prefix. The observer requires ASan load-check symbols in that archive,
a valid C control, and a deliberate expired-handle call detected **inside
`sqlite3_total_changes`** before crediting the Swift Runtime run. System
CommonCrypto/OS libraries remain outside instrumented source. Strict C diagnostics,
strict-memory Swift diagnostics and the test-only C boundary remain in the normal
driver; sanitizer success does not prove all memory behavior.

### Executed results

- macOS arm64 / Swift 6.4: full debug and optimized drivers, **90 discovered Swift functions each**;
  72 process checks; eight generated histories plus four repeated damage-marker
  failures; 26 Runtime construction probes; Core probes, 17 schema tests and
  independent fixture/envelope checks. Every driver command passed.
- Runtime mutation qualification: **19 targeted challenges in both debug and
  optimized builds** (the original 17-case campaign plus incoming-address and
  combined-startup-repair regressions), each following a passing discovered baseline.
- AddressSanitizer with separately instrumented SQLCipher: **30 Runtime functions**,
  archive instrumentation inspection, valid C control and targeted library-internal
  heap-use-after-free negative control passed.
- ThreadSanitizer: **30 Runtime functions passed**, including interleaved receive/save.
  The production SQLCipher archive and system libraries remain outside TSan's
  instrumentation.
- TLA+: **21 SQLite collection checks** and **9 fast-start checks** passed, including
  their named negative controls/witnesses. The combined collection case completed
  **4,884,374 states**. No model/assertion changes were needed.
- App build passed using `XCODE_XCCONFIG_FILE` containing
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR = NO`; the existing deployment-target
  warning remains. The library is still separate from the app target.
- Ubuntu arm64 / Swift 6.1.3: final optimized **90-function suite passed**;
  **eight generated histories and four repeated damage-marker failures passed**.
  **72 fresh-process checks, 26 Runtime construction probes and 12 independently
  inspected zstd envelopes/decoder controls passed** on the VM.
  The actual hardened ELF executable passed the permission observer and its
  negative control. Node 24 was installed for the independent inspector.

Debug/optimized driver artifacts: `nv-storage-phase2-i2s0rpih` and
`nv-storage-phase2-zh2138j7`; final cipher run:
`nv-cipher-sanitizer-fdw1jtbz`; collection TLC run: `nv-segment-tlc-wkjthuoz`,
under the machine's test temporary directory. Mutation artifacts are
`nv-runtime-mutations-8gbawpx6`, `nv-runtime-mutations-7yhxwbde`,
`nv-runtime-mutations-isslw12d`, `nv-runtime-mutations-wmpv6omh`,
`nv-runtime-mutations-hqb2bhw0` and `nv-runtime-mutations-ad3o58k8`.

Linux build qualification: the initial 87-function release run completed normally.
A later SwiftPM planner stalled before compilation. Replaying its six generated
changed-target compile/link commands qualified the final 90-function executable.
The final supported `swift test --build-system native
--use-integrated-swift-driver --disable-build-manifest-caching` invocation then
rebuilt successfully and passed all eight scheduling/isolation test functions.
These driver options match the earlier current-basis VM qualification and are
now encoded in `tests/Makefile`. The generated campaign subsequently passed again
with an independent exact birth-to-body oracle. Both probe and test executables
passed the ELF observer. A separate failed attempt exhausted the VM disk;
six positively identified old synthetic collections were removed under the user's
cleanup authorization, then the unchanged suite passed with free space. These
setup failures are not counted as passing test runs. Final VM logs live under
`/tmp/nv-storage-disk/nv-hardening-final-direct-*`,
`/tmp/nv-storage-disk/nv-hardening-integrated-tests.log` and
`/tmp/nv-storage-disk/nv-hardening-generated-birth.log`.

## Linux executable permissions

The prior Ubuntu Swift 6.1.3 executable really had an RWE load segment. Inspecting
individual link inputs identified writable `.rodata` in Swift-generated
`ASN1.swift.o` and `Probe.swift.o`; a minimal Swift executable did not reproduce it.
The VM's default bfd linker combined those sections with code. Adding only
`-z separate-code` fixed W^X but still omitted GNU_RELRO in the tested link.

Using Swift's bundled lld with `-z relro -z now` produced separate read-only,
executable and writable mappings plus GNU_RELRO and a non-executable stack.
`tests/Makefile` applies these Linux executable-link settings. Library APIs,
validation checks and codec sources are unchanged; no package-level unsafe linker
flags restrict downstream SwiftPM clients. Downstream executable builders must
qualify their actual link results too.

`check-storage-elf.py` inspects ELF program headers for PIE, W^X, non-executable
stack and RELRO; its deliberate writable-code-header mutation must be rejected.
It is part of the Linux Phase 2 driver. Suppressing the warning alone would not
satisfy this check.

## Dependency/security review scope

Reviewed the pinned source/configuration and published upstream advisories on
2026-09-16. This is a release-engineering review of the enabled storage path, not
a claim of a comprehensive cryptographic/security audit.

| Dependency | Pin and relevant findings |
| --- | --- |
| SQLCipher | `c4b275a47932888216bade83aff2bbc73df0ff85`, reports 4.19.0. The pinned changelog labels 4.19.0's release date provisional; reproduce by commit, not a presumed final release tag. Static library, extensions disabled, memory-only temporary storage; runtime verifies cipher/WAL/FULL settings. Changelog includes failed-rekey reporting and partially initialized context fixes. |
| Swift Crypto | 4.5.2 / `da9d28d69ebe3894b18376c8f2395c2f37b8448f`; beyond the fixed versions for [RSA failed-parse double-free](https://github.com/apple/swift-crypto/security/advisories/GHSA-8q93-f6xh-4f6f) (4.5.1) and [X-Wing length validation](https://github.com/apple/swift-crypto/security/advisories/GHSA-9m44-rr2w-ppp7) (4.3.1). NV's enabled calls use SHA-256/HKDF/AES-GCM rather than those APIs. |
| Swift ASN.1 | 1.7.2 / `d9a5b37470adc940d22c3bcd5ca6953a516b727f`, transitive dependency pinned by `Package.resolved`; no ASN.1 storage wire format introduced. |
| zstd | 1.5.7 / `f8745da6ff1ad1e7bab384bd1f9d742439278e99`; vendored portable C, assembly and pre-1.0 decoding disabled. Provider wrapper enforces bounded single-frame, dictionary-free decoding. BSD license retained. |
| Argon2 | `f57e61e19229e23c4445b85494dbf7c07de721cb`; portable reference implementation, serial four-lane fixed profile, retained upstream CC0/Apache license and independent vectors. |
| Platform crypto | CommonCrypto/CryptoKit on Apple; observed OpenSSL 4.0.1 on Ubuntu for SQLCipher, Swift Crypto's own backing implementation for envelopes. These are separate surfaces. |

The [SQLCipher](https://github.com/sqlcipher/sqlcipher/security/advisories),
[zstd](https://github.com/facebook/zstd/security/advisories) and
[Argon2](https://github.com/P-H-C/phc-winner-argon2/security/advisories) advisory
listings showed no published advisories; absence there is not proof of absence of
vulnerabilities. The VM's OpenSSL 4.0.1 is older than published
[4.0.2 security fixes](https://openssl-library.org/news/vulnerabilities-4.0/index.html).
For example, the empty-ciphertext issue concerns AES-OCB/ChaCha20-Poly1305 via
`EVP_Cipher`; SQLCipher's inspected path uses AES-256-CBC with
`EVP_CipherUpdate`/`Final_ex`, HMAC and random generation. This specific advisory
does not establish an NV exposure. A supported patched system-crypto baseline
still needs qualification before shipping Linux binaries; this campaign does not
certify the disposable VM as a production security baseline.

## Model correspondence and remaining boundaries

`SQLiteFastStartSafety.Materialize` already advances one complete batch, matching
the new concrete catch-up loop. `SQLiteCollectionSafety` still supplies atomic
acceptance, dependency closure, wakeups, retained history and recovery obligations.
Pre-acceptance traversal and rejected input are outside their accepted-history
state: they do not justify adding accepted edges or weakening any invariant.
No modeled safety condition changed. Runtime scheduling/fairness, raw payload
decoding and failure to write a discovered-damage marker require the executable
tests above; the models are not credited with proving those implementation details.

The current Intel macOS hosts could not be reached for this revision. Earlier
Intel runs remain dated evidence, not fresh qualification of these edits. Actual
physical power-loss behavior remains unqualified. Large-bootstrap scheduling,
future provider raw-input quarantine, later conflict/undo reducers, row-compression
integration and final store activation remain their separately listed increments.
