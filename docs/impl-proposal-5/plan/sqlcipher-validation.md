# SQLCipher private-store validation

**Current startup decision (2026-09-14):** packed/cache-plus-tail fixtures below describe the measured experiments, not a supported private format. [Current-row startup](../LocalStore.md) replaces that representation. The key, journal, corruption, backup and VFS qualifications remain required independently of packing.

Exploratory results, 2026-09-13. This qualifies the
[SQLite experiment](sqlite-local-store-experiment.md); it does not adopt a new
provider format, dependency or production storage adapter. The later adopted
[database-key and repair policy](../LocalStore.md#database-keys-and-password-free-recovery)
uses these findings; the September 13 follow-up below tests its native mechanisms.

## Conclusion

Always-encrypted SQLCipher is a credible private-store option. Measured startup
overhead was modest, indexed startup did not scan retained history, and the
existing 18 transaction/crash/error checks passed with encryption.

Native `sqlite3_rekey` avoids implementing a database migration engine. A
master-key wrapper is **optional**, not a prerequisite. However, the tested
build failed the stronger qualification that a successful rekey return means
the new key was durably installed: three injected late failures returned
success but left the database readable only with the old key. No tested fixture
lost its history. Do not retire the old credential based solely on that return.

## Build and measurement boundaries

- Apple Silicon, macOS 26.6.2; SQLCipher Community **4.19.0**, commit
  `c4b275a47932888216bade83aff2bbc73df0ff85`, SQLite **3.53.4**, CommonCrypto.
  Dependencies were built in a temporary directory, not installed globally.
- Encrypted and unencrypted controls use the **same SQLCipher binary**. Raw-key
  mode uses public synthetic keys, never real credentials or collections.
- 4 KiB cipher pages, 4 MiB SQLite cache, mmap disabled, memory-only temporary
  storage (`TEMP_STORE=3`), `synchronous=EXTRA`, `fullfsync=ON`. Default page HMAC
  remains enabled. Extended `cipher_memory_security` was off.
- Startup measurements are fresh processes. Cold cases invalidate fixture
  pages, assert zero residency with `mincore`, then verify kernel-reported
  physical reads. They do not flush the SSD's internal cache. No disk image was
  needed. Separate plaintext benchmark files intentionally remain as controls.
- Medians of three measurements, except rekey scaling, which is one sample per
  size/journal mode. Timings are observations, not product latency guarantees.
  The performance-profiling skill guided separation of unlock, load, decoding
  and recovery costs rather than attributing all launch time to encryption.
- These are container/crypto experiments, not NV causal replay, provider sync,
  power-loss qualification or an audit of every application plaintext path.

## Startup and recovery

### Real legacy note reconstruction

10,000 notes, about 4,096 UTF-16 code units per body, 100,000 unrelated historical
4 KiB objects. Current values occupy 44.12 MB; the real compressed FrozenNotation
archive is 12.20 MB. The probes link actual `NoteObject`, `FrozenNotation`,
preferences and compression code and check exact common field bytes. No real
window/controller or collection is opened.

Cold medians, milliseconds:

| Current-state representation | Unencrypted load / total | Encrypted load / total |
| --- | ---: | ---: |
| FrozenNotation archive in one BLOB | 8.0 / 527.3 | 21.5 / 539.3 |
| Flat current values in one BLOB | 23.3 / 545.4 | 68.7 / 593.7 |
| Compressed flat values in one BLOB | 7.1 / 561.3 | 17.1 / 573.7 |
| One current-value record per row | 115.9 / 636.8 | 74.5 / 598.6 |

The independent unencrypted FrozenNotation **file** baseline was 520.5–523.6 ms.
Reconstruction still dominates these large-note fixtures. Do not interpret the
row result as evidence that encryption accelerates SQLite: different packing
and read scheduling, including time spent decrypting between reads, can change
observed I/O behavior. The bulk-cache comparison is the cleaner isolation.
All 72 warm/cold measurements across the two runs passed equality checks.

### History-independent current loading

The existing synthetic cache-plus-32-application-suffix probe took **4.31 ms**
with 10,000 historical objects and **4.34 ms** with 100,000. It requested about
1.25 MB at either size with zero SQL full-scan steps. Full synthetic replay took
112 ms and 1,122 ms respectively. The suffix correctly includes an object that
was stored before the cache but only applied afterward; object insertion order
does not substitute for transactional application order.

All 36 queries and 18 encrypted crash/error cases passed. This part counts VFS
read requests with OS caches warm; it is not the cold comparison above.

### Uncheckpointed WAL recovery

Each writer was killed after committing its backlog. A stopped DB+WAL copy,
without shared memory, forced reconstruction of the WAL index. DB and WAL pages
were evicted before each process. Startup reads the schema, one 1 MiB cache and
an indexed last historical row; it does not replay NV's complete history.

| Committed WAL size | Control startup | Raw-key startup |
| --- | ---: | ---: |
| No WAL | 1.90 ms | 2.57 ms |
| 4.71 MB | 5.97 ms | 7.28 ms |
| 47.08 MB | 23.14 ms | 24.70 ms |

All 18 recovery observations verified expected contents. A held reader prevented
checkpoint progress (1,144 frames, zero checkpointed); releasing it allowed
complete truncation. Keep read transactions short and monitor WAL growth. This
does not establish a bound for arbitrarily large WALs.

### Unlock cost

With OS caches warm, open/key/schema access took a median **0.20 ms** unencrypted,
**0.26 ms** using a raw key and **95.60 ms** using SQLCipher's default passphrase
derivation. Raw-key supply avoids that password KDF, not page decryption. It
does not require a wrapper: NV could supply an already derived/keychain-held
key under either design. Do not weaken a KDF to lower startup latency.

The API accepts a wrong key initially; a query establishes whether it works.
Tests reject missing/wrong keys and demonstrate that 32 binary bytes are treated
as passphrase input, **not** the documented `x'hex'` raw-key syntax.
[SQLCipher key API](https://www.zetetic.net/sqlcipher/sqlcipher-api/#key).

## Native rekey: cost and incomplete qualification

Rekeying rewrites existing encrypted pages rather than exporting schema/history
into a new store. It does not convert an existing plaintext database to an
encrypted one. [SQLCipher rekey API](https://www.zetetic.net/sqlcipher/sqlcipher-api/#rekey).

| Database size | Journal mode | Rekey call | Peak journal/WAL logical extent |
| --- | --- | ---: | ---: |
| 10.3 MB | WAL | 76 ms | 10.36 MB |
| 10.3 MB | DELETE | 167 ms | 10.32 MB |
| 462.0 MB | WAL | 2.28 s | 464.72 MB |
| 462.0 MB | DELETE | 5.51 s | 462.99 MB |

Timings stop when `sqlite3_rekey` returns: final close, checkpointing and
independent verification are additional work. Journal extent is measured from
successful writes, not physical APFS allocation or a universal free-space bound.
Existing WALs and backups can increase total space needs. Rekey work grows with
retained history even when live notes and startup cache stay small.

Small fixtures exercise two process-kill cuts, early disk-full failure, two
sync-error positions and a last-write disk-full failure in both journal modes.
Old/new keys are tested in independent stopped fixture copies. The final
verifier checks the entire cache and every historical row/ID. Ordinary rekeys
open with the new key; interrupted/failed ones in this sample recover with the
old key.

**Repeated counterexample:** the last-write failure in both modes, and the second
sync failure in WAL mode, returned `SQLITE_OK` from rekey and reported no
connection error, yet only the old key could reopen the database. Earlier
failures returned `SQLITE_FULL` or `SQLITE_IOERR_FSYNC`. The forwarding VFS
injects the documented error before performing that one write/sync; the runner
checks that injection fired and never uses two keys concurrently on one file.

The pinned `sqlite3_rekey_v2` calls `sqlite3BtreeCommit` without assigning its
return value to `rc`, then copies the write-key context. That provides a concrete
explanation consistent with the fault result, rather than assuming corruption
or confusing key acceptance with decryption success.
[Pinned implementation](https://github.com/sqlcipher/sqlcipher/blob/c4b275a47932888216bade83aff2bbc73df0ff85/src/sqlcipher.c#L3910).
No upstream source was patched and no issue was posted.

The runner deliberately exits unsuccessfully after saving all results when
this success/verification claim fails. It does **not** call that claim satisfied
merely because contents remained recoverable. Resolve/qualify this behavior
before production reliance. Key retirement also requires a crash-safe transition
outside SQLite: retain old and candidate credentials, quiesce other connections,
verify the new-key reopen, then switch the durable credential reference. Exact
cutover/recovery and mixed-page damage handling remain implementation tests,
not proven by one schema read or these selected fault cuts.

## Alternatives evaluated before the recovery-policy decision

1. **Native rekey:** change from one database key to another. A random device-kept
   secret would provide local confidentiality without password entry, but creates
   a recovery dependency. That is **not** the adopted password-free goal, which
   explicitly favors self-contained recovery over confidentiality. Password changes can use native rewriting, subject to the
   qualification above, writer quiescence and space.
2. **Stable database key plus wrappers:** replace/add an authenticated wrapper
   on password change. This avoids whole-history work but requires a small
   external unlock descriptor and its crash-safe lifecycle.

The Swift mechanics probe tested option 2 with CryptoKit AES-GCM, a random
256-bit database key and the proposed Argon2id profile (64 MiB, three passes,
four lanes). Setting, changing and removing the password requirement left the
closed DB byte-for-byte unchanged and readable through its applicable unlock
route. Wrong password, wrong store context and damaged wrappers were rejected.
Three KDF operations took 26–52 ms using the generic reference build; the sealed
32-byte key is 60 bytes, plus salt/header metadata.

The probe keeps wrappers/device keys in memory. It does **not** qualify Keychain,
credential-file durability, backup recovery, removal of old credentials or secure
erasure. A retained old wrapper still unlocks the same database key, as tested.
Rekey likewise cannot revoke access to retained old database backups.

The adopted design needs neither a second random private key nor a separate
private wrapping protocol: password-free databases use a documented public key,
encrypted ones derive their raw key from CK. Existing same-CK password rewrapping
therefore changes no database key. The original device-wrapper probe remains a
mechanics experiment, not password-free product behavior. Native rekey is not
used routinely; the findings still matter if a future storage-key migration uses
it. SQLCipher's password KDF does not replace NV's provider Argon2 contract.

## Adopted key, backup and salvage follow-up

`SQLCipherRecoveryProbe.swift`, run through the existing driver with
`--key-recovery-only`, passed **29 checks plus two independently calculated key
vectors** on the same arm64 SQLCipher 4.19.0/CommonCrypto build. Artifacts:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-sqlcipher-variation-vbxbxrd5/results.json`.

- A child committed a public-key database and was killed by SIGKILL. Another
  process opened a renamed DB/WAL copy without SHM, Keychain, provider access,
  original folder identity or a key sidecar and recovered the exact contents.
- A correctly keyed SQLite backup taken from a fixed read transaction, with
  committed work still in the live WAL, included all three captured object rows,
  their pin and private frozen input/link. The source writer added a fourth object
  and changed that input/link after capture without changing the backup's view.
  A main-file-only copy contained only the first object: it was readable but
  incomplete. Protected backups rejected the public key and wrong collection.
- Two Argon2id/AES-GCM password wrappers for the same CK independently reopened
  that protected backup, rejecting wrong passwords. Database bytes were unchanged
  by the wrapper mechanics. The fixture wrappers are not the unfinished NV wire
  descriptor or a durable credential-transition implementation.
- Corrupting one actual encrypted object-overflow page left that object unreadable.
  **The initial same-connection salvage attempt also failed on the two intact
  rows.** Fresh keyed working-copy connections recovered both, including the
  unique unpublished object, and the private input. The pinned source sets a
  persistent codec error (`sqlcipher_codec_ctx_set_error`); this is a recovery
  usage constraint, not a claim that SQLCipher violated its API contract.
- A fresh sibling reconstructed from that salvage plus an exact provider copy
  reopened with all three objects and private state; the damaged original stayed
  byte-for-byte unchanged. Fixture-oracle checks reject omitted unpublished work,
  omitted private input and fabricated bytes. These check candidate validation,
  not a production NV reducer/descriptor codec or arbitrary damaged-page salvage.
  Low-level `.recover` output and its uncertain transaction provenance are not
  exercised or authorized as accepted NV history by this probe.

Reproduce with the existing qualified source builds:

```sh
python3 tests/run-sqlcipher-variation-probe.py \
  --sqlcipher-build /path/to/sqlcipher \
  --argon2-build /path/to/argon2 --key-recovery-only
```

Public-key vector: `700943ee44e9d3d7264d9427e968db21c7ea09e23f2872654ff1711ac1af8afe`.
For CK bytes `00..1f`, collection bytes `20..2f`, key-ID bytes `30..3f`, the
encrypted database-key vector is
`edf44bde3a72dcc7983f80da641810af4922ecf0548faa43ca1e5155cc3e0376`.
The runner cross-checks CryptoKit against Python stdlib SHA-256/HMAC HKDF.

Still unqualified: production descriptor/selection codecs, durable external
descriptor-to-SQL and selected-store activation crash cuts, permissions/full-disk
backup failures, arbitrary schema/index/multiple-page damage, Intel and other
platforms, signed-app remembered unlocking and power loss. The existing repair
model covers abstract union/pin/activation ordering, not these native steps.

## Other contingencies

- **Encryption scope:** database page encryption covers current values/indexes,
  not only segment BLOBs. SQLCipher also encrypts journal/WAL data pages; file
  sizes/access timing and some journal metadata remain observable. Memory-only
  temporary storage is required; plaintext exports/logs remain application
  responsibilities. [SQLCipher design](https://www.zetetic.net/sqlcipher/design/).
- **On-read authentication:** corrupting one positively located historical
  overflow page left unrelated cached startup readable. Reading that history
  failed with `SQLITE_CORRUPT`; `cipher_integrity_check` found one damaged page.
  Successful open does not authenticate unread history or establish freshness.
  Do not add a mandatory full-history startup scan.
- **Recovery:** `NV Data` restores history actually present and readable there,
  not unpublished changes/private settings lost with the local DB. Retain damaged
  stores for salvage. Wrong keys, unavailable credentials and corruption must
  not become “create an empty replacement.” Secret loss needs a backup/recovery
  policy for encrypted stores. Password-free recovery now uses the documented
  nonsecret key, so no private key/Keychain loss can strand otherwise usable bytes.
- **Existing spec:** local page encryption does not change the provider profile.
  Keep exact canonical provider envelopes and their independent validation.
  Never sync DB/WAL/SHM. [Encryption](../Encryption.md) and
  [ADR 0011](../../adr/0011-use-source-preserving-key-and-profile-transitions.md)
  still distinguish same-key descriptor rewrap from source-preserving destination
  conversion for provider key/profile changes. Local rekey is not that protocol.
- **Remaining qualification:** Intel/macOS and portable-platform builds,
  signed-app credentials, realistic per-action commit frequency, larger WALs,
  filesystem/power-loss behavior, key-cutover fault matrix, memory sanitization,
  backup/salvage and production Swift/AppKit linkage. SQLCipher shares SQLite
  symbol names: avoid accidentally linking/keying system SQLite instead.

## Reproduction and evidence

Build SQLCipher tag `v4.19.0` at the commit above in a disposable directory:

```sh
./configure --disable-tcl --disable-shared --disable-load-extension \
  --with-tempstore=always --dbstat \
  CFLAGS='-O2 -mmacosx-version-min=11.5 -DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown -DSQLCIPHER_CRYPTO_CC'
make -j4 libsqlite3.a
```

Then from the NV checkout, substituting your build paths:

```sh
python3 tests/run-sqlite-local-store-probe.py --sizes 10000 100000 --repeats 3 \
  --sqlcipher-build /path/to/sqlcipher --key-mode raw
python3 tests/run-startup-storage-comparison.py --skip-build --notes 10000 \
  --body-chars 4096 --history 100000 --repeats 3 --conditions warm cold \
  --sqlcipher-build /path/to/sqlcipher --key-mode none
# Repeat the preceding command with --key-mode raw.
python3 tests/run-sqlcipher-variation-probe.py --repeats 3 \
  --sqlcipher-build /path/to/sqlcipher --argon2-build /path/to/argon2
```

Omit `--skip-build` if current app objects have not been built. Optional Argon2
reference build: tag `20190702`, commit
`62358ba2123abd17fccf2a108a301d4b52c01a7c`, `make libargon2.a OPTTARGET=none`.
Omit `--argon2-build` to skip wrapping.

Sources: [runner](../../../tests/run-sqlcipher-variation-probe.py),
[C mechanics](../../../tests/SQLCipherVariationProbe.c),
[Swift wrapping](../../../tests/SQLCipherKeyWrappingProbe.swift).
All generated DBs contain synthetic data in temporary directories. Never use
these public fixture keys with user data.

Raw results under `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`:

- `nv-sqlite-local-probe-q5ore50_/results.json`: encrypted indexed/crash suite.
- `nv-startup-comparison-furr7znu/results.json`: same-engine unencrypted control.
- `nv-startup-comparison-hl7mq_0l/results.json`: encrypted real-note comparison.
- `nv-sqlcipher-variation-cy4rmezo/results.json`: three-repeat recovery/unlock,
  rekey faults/scaling, damage, held reader and wrapper results quoted above.
- `nv-sqlcipher-variation-97ta6ee3/results.json`: final one-repeat regression,
  strengthening rekey verification to include the complete cache and ordered IDs;
  failing exit for the same three rekey success/verification counterexamples.
- `nv-sqlite-local-probe-gqu_73r4/results.json`: original system-SQLite smoke
  regression after VFS changes; six queries and 18 crash/error cases passed.

No production source, normative policy or TLA model changed. The unchanged app
and TLA suite were not rebuilt for these isolated test extensions.
