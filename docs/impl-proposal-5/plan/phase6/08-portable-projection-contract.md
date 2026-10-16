# P6.1 — Portable projection descriptions in Changes

This implements transport placement for the [complete history binding](03-history-observation-contract.md).
It preserves the distinction between a source claim, accepted history, checked
Current, and an actual local file observation. See the
[completion ledger](06-completion-ledger.md) for producer/consumer qualification and boundaries.

## Current v1 layout

Changes retains its dependency, operation and action sections. A nonempty optional
projection section follows them:

| Field | Canonical representation |
| --- | --- |
| Section marker | Eight bytes `NVPRJ1\r\n` |
| Count | Big-endian u32, strictly positive |
| Each description | u32 byte length followed by complete `ProjectionBindingV1` bytes |

The empty set is encoded by section absence. A present zero count, repeated or
out-of-order bindings, unknown trailing data and partial records fail. Bindings
are strictly ordered by their entire encoded bytes. The aggregate Changes payload
retains the existing 64-MiB ceiling, including this section and its framing.
This is an optional field in the single current unreleased v1 definition, not a
reader branch for a superseded development format.

Every source occurrence is external: a descriptor names already retained source
history, avoiding a circular reference to its own envelope. Its exact dependency
locators must occur in the containing Changes dependency table. The containing
table can also include ordinary action/operation dependencies and captured
accepted Changes tips for [retention coverage](11-projection-producer-contract.md#retention-coverage).
These additional dependencies retain bytes independently of the binding's exact
source set. A metadata-only
Changes object has zero operations/actions and the complete description section;
it preserves projection provenance without creating an echo edit or undo action.
Ordinary groups may share that envelope when independently valid.

Descriptors participate in the enclosing envelope bytes/hash and retention graph.
They remain outside note-value, operation and action identity preimages. Their
presence never selects Current or records physical installation. Multiple claims
remain historical claims; receiving their order does not select a filesystem winner.

## Checked context and source validation

The envelope issuer retains its checked collection and profile in immutable
`OpenedObjectV1` fields. Its initializer stays file-private. Contextual Changes
decoding accepts projection descriptions only for the plaintext profile and the
same collection. Public-profile checksums establish exact bytes; encrypted
envelopes additionally authenticate them. All production intake, initial import,
retained reads and reconstruction consumers use this contextual decoder.

Before acceptance, resolve every exact locator/index/operation identity and birth.
Ordinary and automatic sources use their existing value/key checks. Equal/merged
sources follow exact note-predecessor occurrences, reuse each decoded envelope
within that traversal, and invoke the shared standalone derived-state validator.
It checks the complete represented set, result digest and applicable unique-base
and merge identity. A complete source wider than the stamp's 4-KiB limit remains
valid here; the optional xattr is omitted in full.

Missing inputs park through existing accepted-history requirements; rejected
prerequisites retain their existing blocking reasons. Source checking runs on the
historical worker for descriptor-bearing objects, including objects that also
carry ordinary edits. Dependency-closed acceptance, bytes, membership, retention
edges/frontier and wakeups commit in the existing atomic transaction. Metadata-only
acceptance advances the local acceptance prefix while leaving logical state intact.

Local/private accepted observations remain unchanged by receipt of a portable
description. File-byte/encoding equality, unique applicability, current root and
physical receipt checks remain necessary before association or installation.
The [complete query consumer](10-complete-binding-query-contract.md) reads exact
accepted descriptions and checks their full sources; it retains distinct
issuer-restricted evidence alongside the stamp-specific result type. The
[local producer](11-projection-producer-contract.md) freezes verified owned outputs
and reuses exact sealed bytes through existing durable receive ownership. No database table,
sidecar, timer or global descriptor scan is introduced by this transport increment.

## Verification boundary

[Qualification](08-portable-projection-validation.md) records independent bytes,
actual receipt/reopen/rebuild, parking and transaction rollback, source and
profile failures, compiler probes and targeted mutations. Existing models already
assume complete exact source validation and atomic accepted dependency retention;
this increment implements those premises without changing a modeled transition.
No physical-file authority or power-loss guarantee is inferred from these checks.
