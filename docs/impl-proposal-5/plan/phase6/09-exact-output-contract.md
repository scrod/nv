# P6.1 — Exact encoded output retention

This implements the result of the [encoding investigation](05-text-encoding-investigation.md):
preserve the requested-encoding/UTF-8-promotion policy and retain actual output
when an encoding identifier cannot reproduce it portably. Native Foundation
conversion remains on the history worker. Canonical note bodies stay unchanged.

`ProjectionEncodingV1` is a positive UInt64 NSString encoding identifier.
`PreparedProjectionTextV1` has an issuer-private initializer; its public preparer
uses NSString's lossless conversion and promotes failure to the canonical body's
exact UTF-8 bytes. The resolved encoding and bytes form one immutable result.
An encoding request is platform input, not a promise of identical native codec
availability. Once captured, recovery preserves identical bytes across platforms
without invoking that native codec again.

## Current v1 private layout

The output's encoding byte is an exhaustive source discriminator:

- `1`: exact UTF-8 bytes reconstructed from its retained note source.
- `2`: captured output, followed by big-endian UInt64 resolved encoding and
  UInt64 byte count. The encoding is positive and different from UTF-8 (4); the
  count fits a signed SQLite length. The normal complete binding follows.

The output generation, binding and observation framing are unchanged. This
directly extends the current unreleased layout. Independent fixtures include
UTF-16 external representation bytes and their output digest.

Captured bytes are required private inputs in existing `private_groups` rows.
Keys are ASCII `projection-data/<32 lowercase birth hex>/<64 lowercase digest hex>/<16 lowercase chunk
index hex>`, with generation 1, codec 1. Consecutive zero-based chunks contain
exactly 1 MiB except the last; an empty output has no chunks. The digest is the
descriptor's SHA-256 over the complete output. Identical byte outputs reuse the
same chunks within one note; existing differing bytes fail rather than being overwritten.
The birth scope permits local owner checks when releasing superseded outputs.
Different notes with identical bytes have independent private copies.
Chunking preserves the per-record ceiling without imposing a new smaller note
limit when an encoding expands its source. Consumers allocate from actual read
chunks, never from the claimed aggregate length.

The chunk set and new intent commit in one private transaction after the existing
store/session/current-view/association/private-generation checks. Failure leaves
both the prior owner and data unchanged, or commits both together under the
existing ambiguous-completion rules. Accepted and captured source descriptions
remain intact. Exact bytes are available in the prepared intent before commit;
this is preparation, not a durability receipt or physical write permission.

Opening checks referenced chunk keys, codecs and exact sizes without decoding
historical envelopes or loading every encoded body. The encoded-byte consumer
requires the current store-issued observation capture and exact owned output,
reads bounded chunks, verifies the aggregate digest off the database lane and
rechecks the capture before returning. Missing/changed required bytes fail;
recovery never regenerates them with another host's encoder. Complete private
backup and complementary repair preserve the chunk union; conflicting rows leave
repair incomplete. Repository-only copies retain their existing history-only
scope rather than acquiring local pending inputs.

[Frozen transition ownership](13-frozen-output-contract.md) preserves an admitted
output and its captured source independently of later intentions. Superseded
unowned chunks are removed in the same transaction as the intent switch, using
only that note's old and new owners and indexed chunk ranges. Accepted, intended,
captured-source and frozen owners all protect bytes. A frozen transition remains
retained through restart until later physical settlement integration can transfer
its ownership safely. The [complete settlement-record mapping](14-settlement-record-contract.md) closes that P6.1 gate;
physical receipt issuance and publication belong to P6.2/P6.4.

## Required qualification

Independent bytes and framing, UTF-8 exact preservation, requested encoding and
fallback, empty/BOM/NUL/NFD cases, multiple chunks, digest-versus-size corruption,
same-type wrong store/session/generation, atomic rollback, fresh reopening,
complementary repair and process failures. Compiler challenges cover prepared
byte immutability and issuer construction. Mutations must reach the exact byte,
digest, context or atomic-owner assertion. Platform evidence remains distinct
from the failed encoding-ID-only reconstruction hypothesis.
