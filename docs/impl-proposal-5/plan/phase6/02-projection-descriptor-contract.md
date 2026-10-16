# P6.1 — Exact filenames and portable projection descriptions

This slice follows the [stamp codec](01-projection-record-contract.md) and the
[Phase 6 dependency plan](../phase6-plaintext-reconciliation-plan.md). It freezes
the passive descriptor value and exact filename boundary. The
[history/private-observation slice](03-history-observation-contract.md) adds its
private source binding and intent writer. The [portable Changes section](08-portable-projection-contract.md)
now defines segment placement. [Exact encoding preparation](09-exact-output-contract.md)
retains native output bytes privately. The [local producer](11-projection-producer-contract.md)
adds exact-byte admission/retry; retention-growth qualification, settlement-owner
release and physical consumers retain their separate gates.

## Legacy inventory and adaptation

| Existing behavior | Source | Phase 6 treatment |
| --- | --- | --- |
| Title `/` becomes `:`; leading `.` becomes `_` | `NotationDirectoryManager.m`, `uniqueFilenameForTitle:fromNote:` | Preserved by the captured output-name generator; observed leaves retain their exact spelling |
| Retain a permitted current extension, otherwise use the selected extension | Same function; `NotationPrefs` extension settings | Capture the actual selected format/extension with prepared output |
| Reserve `3 + extension.length + 2` UTF-16 units below 255; collisions replace the last basename extension with `.1`, `.2`, … | Same function; `NSString_NV.m`, `filenameExpectingAdditionalCharCount:` | Preserved by the generator, with tested scalar-safe surrogate truncation |
| Case-insensitive basename comparison against other notes and whole-name comparison against the directory | Same function; `NVRootedDirectory.m`, `caseInsensitiveRegularFileExistsNamed:excludingName:` | Sorted captured sets support candidate searches; coherent catalog capture and fresh physical checks belong to the caller |
| Case-insensitive catalog duplicates stop reconciliation even on case-sensitive volumes | `NotationDirectoryManager.m`, `_catalogContainsCaseInsensitiveCollision` | Keep ambiguity explicit; lexical filename validity alone never selects a winner |
| Rooted leaf validation rejects empty, slash, NUL, `.` and `..`; OS representation is checked separately | `NSFileManager_NV.m`, `NVCopyFileSystemNameForLeaf` | Core validates structure; the adapter checks actual filesystem representation, length, kind and symlink safety |
| Unrepresentable requested output encoding promotes to UTF-8 | `NoteObject.m`, `NVCreatePlainTextDataPromotingToUTF8` | Preserve exact resulting bytes and resolved encoding together; changing encoding changes the projection digest, independently of semantic note identity |
| File decoding may use an observed encoding or a fallback/guess | `NoteObject.m`, snapshot initializer; `NSString_NV.m`, `newShortLivedStringFromData:ofGuessedEncoding:` | Keep observed encoding presence and decoding result separate |
| Tags distinguish absent from present-empty before note creation fills defaults | `NVRootedDirectory.m`, `snapshotForFileNamed:`; `NotationDirectoryManager.m`, `_preparedNoteForCatalogEntry:` / rename candidate staging | Preserve presence before supplying fallback labels; guessed/fallback labels cannot become association evidence |
| Creation date falls back to existing note date, then current time | `NoteObject.m`, snapshot initializer | Retain the raw observed date independently of import presentation values; later matching never treats a fallback timestamp as evidence |
| Coherent read compares pre/post descriptor observations and final name binding | `NVRootedDirectory.m`, `snapshotForFileNamed:` | Preserve this physical read contract; passive record decoding cannot issue that evidence |
| Encoding, OpenMeta tags including empty sets, and requested dates are mandatory; Finder mirrors are best effort | Rooted note writer and [Foundation replacement contract](../../../Foundation-Safe-Replacement-Migration.md) | Maintain distinct mandatory-metadata and optional-stamp outcomes |

The [captured filename-preparation increment](04-filename-preparation-contract.md)
now adds the output-name generator and its independent boundary/collision tests.
This descriptor contract still separates selected spelling from fresh physical
occupancy and installation evidence.

## Filename value

`ProjectionLeafNameV1` contains immutable `ExactUTF8`. Reject empty names, NUL,
POSIX `/`, `.` and `..`, and case-insensitive spellings of the actual reserved
root entries: `NV Data`, `Notes & Settings`, `Interim Note-Changes`.
On the supported macOS/Linux POSIX roots, `:` and backslash are literal filename
characters; they are not converted into separators. A future adapter for a
different path grammar requires its own capability qualification.

Preserve all accepted UTF-8 bytes, including decomposed Unicode and case.
Equality/hashing is exact. `compare(to:)` returns `exact`, `alias` or `distinct`:
an alias is a different spelling that NV's Foundation case-insensitive comparison
considers equal. It supplies a collision classification, never a file-association
or deletion decision. Swift `String` equality alone is insufficient here because
it equates canonically equivalent spellings.

Use the existing canonical text/payload bounds at the wire boundary. Physical
filename limits belong to the volume adapter; structural validity is not a
promise that a particular volume can create the leaf. The output-name generator
must enforce its legacy length/extension policy separately.

## Descriptor bytes and identity

`ProjectionDescriptorV1` describes the exact intended output. Its fields are:

| Field | Encoding |
| --- | --- |
| Magic | Eight bytes `NVPRD1\r\n` |
| Version | Big-endian `u16(1)` |
| Filename | Existing length-prefixed `ExactUTF8`, validated as `ProjectionLeafNameV1` |
| Content format | `u16(1)` for plaintext |
| Exact output digest | 32-byte `ProjectionBytesDigestV1` |

Total size is `48 + filename UTF-8 byte count`, bounded by the existing decoded
payload ceiling. Reject unknown tags, malformed UTF-8, invalid/reserved leaves,
truncation, impossible lengths, trailing bytes and encrypted-profile presence.
An empty **body** has its normal SHA-256 digest and remains valid.

This descriptor carries the Protocol's path/format/exact-byte tuple. The stamp
separately carries collection/birth/source references; both remain passive
claims. Local encoding, raw metadata presence, physical identity, accepted/intended
generation and source-removal obligations belong to their later private records.
The digest binds exact encoded output even when its bytes use an encoding other
than UTF-8.

Presence is permitted only for `PlaintextFilesV1`; encrypted-profile construction
and decoding fail explicitly. Absence stays representable at the eventual
containing record and supplies no path-match evidence. This slice does not add a
descriptor to `PlaintextNoteValue` or an action, and changes no existing
value/operation hashes. The later [portable placement contract](08-portable-projection-contract.md)
defines containing-record source bindings and hash participation with independent preimages; before
physical use, require fresh rooted authority and exact history applicability.

## Qualification

`ProjectionDescriptorTests.swift` compares three independently assembled Python
fixtures, checks every truncated prefix and all fields, distinguishes NFC/NFD
spelling from collision aliases, checks unsafe/reserved names through construction
and decoding, rejects wrong profiles/formats/lengths, and exercises the existing
payload ceiling. Ordinary and same-module compiler probes enforce the leaf's
nominal role, immutable spelling/filename and descriptor/stamp distinction.

Three `p61-descriptor-*` mutations challenge case-sensitive reservation, path
normalization and canonically-equal string substitution. Each requires a passing
companion, nonzero discovery and the intended assertion. See the
[validation ledger](02-projection-descriptor-validation.md) for commands/results.
This adds concrete value checks below the existing model assumptions; no modeled
transition or safety condition changes.
