# P6.1 — Projection stamp record contract

This is the first record slice of the [Phase 6 plan](../phase6-plaintext-reconciliation-plan.md).
It implements the advisory stamp's canonical values/codec. Physical xattr writes,
history-backed association, portable path descriptors and private installation
receipts retain their separate P6.1–P6.5 gates. A decoded stamp is a claim supplied
to those consumers, never an accepted history or physical permission object.

## P6.0 inventory and state allocation

| Responsibility | Existing source / contract | Implementation allocation |
| --- | --- | --- |
| Exact semantic note values and hashes | `PlaintextNoteValue.swift`, `OperationV1.swift` | Preserve existing semantic encodings and IDs in this slice |
| Exact immutable occurrence | `StoredOperationReferenceV1`, `OperationReference`, `SegmentLocator` | Reuse the canonical 56-byte locator and external operation reference |
| Equal-value and two-head derived state | `DerivedStateReferenceV1` | Reuse its sorted complete inputs, result digest, merge version/base/ID and later reconstruction checks |
| Automatic preservation | `AutomaticSourceReferenceV1`, `AutomaticConflictKeyV1` | Reuse exact source birth/revision/key; preserve the distinction from user recovery copies |
| Current materialization | `CurrentNoteCellV1` | Supplies captured provenance to the later writer; parsing cannot promote a passive current cell into accepted-history evidence |
| Pending latest/frozen/reserved/settled input | `PendingFiles.swift`, `PrivateRecordsV1.swift` | Reuse private transaction ownership; replace the synchronous passive-record callback with a real physical consumer in the later slice |
| Coherent observation and deletion preference | `NotationDirectoryManager.m`, `DeletionManager.m` | Port fenced decisions and raw metadata presence; retain targeted review and origin-independent absence policy |
| Actual metadata and replacement | `NVRootedDirectory.m`, Foundation replacement contract | Qualify exact stage/readback/source-accounting before production writes |

This slice adds no persistent table, index, receipt, sidecar or operation kind.
The [filename/descriptor slice](02-projection-descriptor-contract.md) records
the concrete legacy naming/encoding/metadata inventory and implements passive
leaf/descriptor values. The [history/private-observation slice](03-history-observation-contract.md)
implements the complete source binding and accepted/intended description codecs.
The later [portable Changes section](08-portable-projection-contract.md) implements
descriptor placement and source acceptance. The [complete query](10-complete-binding-query-contract.md)
and [local producer](11-projection-producer-contract.md) add checked consumers and
exact retry; rooted receipt issuance remains a separate gate.
In particular, adding optional transport metadata
to a segment must not silently change semantic note hashes or action scope.

## Canonical bytes

Unsigned integers are big-endian. The xattr name is exactly
`org.notationalvelocity.projection#S`; total value length is at most **4,096 bytes**.
There is one current unreleased v1 encoding, with no compatibility branch.

| Field | Encoding |
| --- | --- |
| Magic | Eight bytes `NVPRJ1\r\n` |
| Version | `u16(1)` |
| Collection | Existing nonzero 16-byte `CollectionID` |
| Projected birth | Existing nonzero 16-byte `NoteBirth` |
| Content format | `u16(1)` = plaintext; other values unsupported |
| Exact output digest | 32-byte SHA-256 of the encoded file bytes, including BOM/newlines if present |
| Dependencies | Existing `DependencyLocatorTable`: `u32` count followed by sorted, unique 56-byte locators |
| Represented state | One of the following complete records |

The content-format tag identifies plaintext semantics, not a platform string
encoding number. Exact output encoding belongs to the concrete projection
descriptor/observed metadata; this stamp's digest binds the resulting bytes.
`ProjectionBytesDigestV1` is distinct from the semantic `NoteValueDigest`.
All 32-byte digest values are representable; byte-width validation is separate
from comparing a computed digest with observed output.

| State | Encoding |
| --- | --- |
| Ordinary | `u8(1)` + external `OperationReference` |
| Automatic preservation | `u8(2)` + source birth (16) + automatic key (32) + external source `OperationReference` |
| Equal-value Current | Existing derived tag 3, complete sorted input references and semantic result digest |
| Two-head merged Current | Existing derived tag 4, exactly two input references, merge version 1, base reference, semantic result digest and merge ID |

Every operation reference is external: tag 0, dependency-table index `u32`,
operation-section index `u32`, expected operation ID (32). A standalone xattr
has no earlier-local operation prefix. The dependency table must contain exactly
the referenced locators, without unused entries. Different inputs may share one
locator; one operation ID may not be assigned contradictory occurrences inside
the same state. Derived input sets retain their existing canonical ordering and
duplicate/base restrictions. An automatic stamp's projected birth must equal the
birth derived from its claimed automatic key. History validation later checks
the source value, key, exact occurrence, applicability and deletion context.

Minimum ordinary size with one locator is 178 bytes; automatic is 226 bytes.
Two-input equal and merged records sharing one locator are 255 and 330 bytes.
Reject unknown versions/formats/tags, trailing bytes, local references,
noncanonical or extra dependency entries, invalid identifiers and truncated or
overflowing counts before treating any claims as usable.

## Construction, omission and consumers

`ProjectionStampV1` is immutable, with a checked public value initializer and a
bounded decoder. Both require an explicit profile and reject encrypted-segment
mode. This is format/profile validation, not physical write authorization.
The root writer must still consume its own fresh plaintext-profile authority.

`prepare` preserves a complete valid represented-state claim. When its encoded
size exceeds 4 KiB it returns `omittedOversized`; it never truncates references.
Malformed structure remains an error, including local references. The decoder
rejects oversized received values instead of treating them as an absent stamp.
Required body/encoding/tag errors belong to the physical operation and cannot be
classified as optional-stamp loss by this codec.

The independent fixture script assembles bytes with separate Python integer,
hash and reference code. Swift tests compare literal bytes and every field, and
challenge sizes, order, scope and exact text spelling. Compiler clients challenge
digest-role substitution, immutable fields and attempted conversion to accepted
evidence. Targeted mutations must fail at the registered assertions.

This fills part of the schema/hash assumptions in `ProjectionStampSafety`; it
changes neither model transitions nor safety conditions. No association or
automatic-import qualification follows from a successful round trip. Accepted
history lookup, exact physical bytes, unique applicability and fresh consumer
context remain required by the Protocol.

`DerivedStateReferenceV1.reconstruct` checks nested segment references;
`reconstructStandalone` shares its exact value/head/base/merge checks using
external occurrences and complete selected note ancestry. The
[Runtime standalone reader](07-inbound-history-contract.md) supplies accepted
occurrences and fences their consumer separately from physical association.
