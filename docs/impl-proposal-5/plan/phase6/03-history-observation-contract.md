# P6.1 — History-bound output and private observations

This increment connects the descriptor codec to accepted history and freezes the
private accepted/intended descriptions. It precedes the P6.2 physical receipt
issuer. These private records leave note, operation, action and envelope identities
intact. The separate [portable Changes section](08-portable-projection-contract.md)
now carries history-bound descriptions in envelope bytes, with a
[complete query consumer](10-complete-binding-query-contract.md) and a
[local producer](11-projection-producer-contract.md). Physical applicability and
settlement retain the separate gates in the completion ledger.

## History binding

`ProjectionBindingV1` encodes `NVPBD1\r\n`, u16(1), collection (16), birth (16),
a u32-length-prefixed descriptor, the canonical dependency table, and the same
complete tagged source reference used by the stamp. All references are external;
the dependency table contains exactly their locators. The ordinary 64-MiB decoded
record bound applies. The 4-KiB stamp bound applies only when emitting the optional
xattr. Oversized stamps never shorten the retained source set.

The Runtime prepares output from an owned, checked current capture. It verifies
every referenced accepted occurrence, decodes each selected envelope once, checks
complete action membership/indexed links, reconstructs the value, and compares it
with the captured cell. Current provenance supplies the already validated choice
of represented heads/base. The final private transaction rechecks the current
view, session, connection, association and private generation. Incoming history or
an intervening edit invalidates preparation. A private constructor issues the
prepared value; decoding a binding only produces a claim.

The [standalone reader](07-inbound-history-contract.md) validates incoming stamp
sources independently of checked Current provenance. Its historical result and
current-view relationship remain separate from physical file applicability.

The output preparer preserves the requested-encoding/UTF-8-promotion policy.
[Exact output retention](09-exact-output-contract.md) keeps captured non-UTF-8
bytes in bounded required private rows; UTF-8 uses the exact retained body.
[Captured filename generation](04-filename-preparation-contract.md) supplies the
selected leaf. The descriptor's digest is computed from the actual output bytes;
raw observed metadata remains separately represented.

## Private description layout

`ProjectionObservationsV1`: `NVPOB1\r\n`, u16(1), private scope (64), association
ID (16), birth (16), optional accepted record, optional intended record, optional
frozen transition. Optional
fields use a byte 0/1. Each nested record is u32-length-prefixed. All records use
the existing decoded-payload ceiling, strict end checks and canonical scalars.

- Output: positive u64 generation, u8 source (1 = exact retained UTF-8;
  2 = captured bytes with u64 resolved NSString encoding and u64 byte count),
  length-prefixed binding. Captured bytes use the descriptor digest and the
  [private chunk layout](09-exact-output-contract.md); an encoding ID alone is
  insufficient to reproduce them across platforms.
- Accepted: output, mandatory passive physical observation, four optional passive
  fields for raw encoding, tags, creation date and modification date. Each passive
  field uses the existing codec/u32-length framing. Absence and present-empty are
  distinct. Platform decoding and fallback values belong to the adapter.
- Intended: output, optional captured accepted source. That source remains an
  outstanding obligation until the rooted transition accounts for it. Its output
  generation is strictly earlier than the intended output.
- Frozen transition: the exact intended record captured for the serialized
  per-note transition. It owns its output and source independently of later
  intentions. The [ownership contract](13-frozen-output-contract.md) defines its
  private transaction and byte-release rules.

All nested bindings share collection/birth. Accepted generation cannot exceed
intended generation; an equal generation requires the same output. A frozen
generation follows accepted and precedes or equals intended; equality requires
the exact same transition. All owners naming one output generation agree on its
complete output. An empty set
represents a relationship with no recorded output. These are descriptions of
earlier observations, not live filesystem capabilities.

Store one bounded row per birth under `private_groups`, key ASCII
`projection/` + lowercase hexadecimal birth, codec 1. SQL generation guards the
whole record; output generation identifies the captured output independently.
Saving an intent preserves accepted bytes exactly and captures that source.
Ambiguous/repeated writes are resolved by rereading exact committed state; stale
evidence cannot replace newer intent. Startup and exceptional backup/repair
validate framing and capture scope. Verified sibling repair preserves the original
scope using the existing repair-source records.
Complementary repair unions per-birth observation rows from every source. A
same-key disagreement returns `incomplete` while preserving the sources; repair
does not choose one description by timestamp, local generation or source order.

The Runtime exposes reading and history-checked intention retention in this slice.
Accepted records are decoded and preserved; a production method to advance them
requires P6.2's exact rooted receipt and source accounting. Tests may seed passive
accepted descriptions in SQLite to exercise preservation/reopen, but that is not
qualification of physical settlement. Pending settlement integration and atomic
receipt publication stay gated on that issuer.

## Qualification requirements

Independent Python layouts; all truncated prefixes; absent/present-empty metadata;
complete oversized source sets; wrong collection/birth/profile; exact occurrence
addresses; ordinary/derived/automatic value reconstruction; session/view/private
generation rejection; failed intent writes preserving prior accepted/intended
bytes; reopen and sibling-backup preservation; corrupt versus unsupported private
state. Compiler probes cover both ordinary and same-module construction. Targeted
mutations must fail their designated assertions. Existing projection models keep
their physical checks as obligations for P6.2 rather than acquiring fake witnesses.
