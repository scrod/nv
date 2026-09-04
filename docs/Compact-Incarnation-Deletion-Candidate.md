# Compact incarnation/deletion metadata candidate

Status: experimental design note, not adopted policy. This document does not
modify `iCloud-Drive-Support-Spec.md`, `CONTEXT.md`, any ADR, or implementation
proposal #4. Those documents continue to prohibit UUID xattrs, general note
tombstones, and durable alias records.

## Objective

Explore automatic recognition of intentional remote deletion while adding no
metadata subdirectory, per-operation files, receipt protocol, CloudKit store,
or network wait to the local delete path. Keep separate note files ordinary and
interoperable, preserve each live `NoteObject` UUID against untrusted metadata,
and choose preservation rather than destructive inference when evidence is
missing or ambiguous.

This candidate cannot both garbage-collect its shared history and protect every
new, offline, or restored client. Its compact shared sets are monotonic.

## Candidate representations

### Advisory file identity envelope

An NV-authored note file may carry one fixed, versioned, syncable xattr whose
exact name is independent of runtime preservation-flag support. Its canonical
value contains:

- schema version;
- claimed note UUID;
- random incarnation UUID; and
- SHA-256 of the exact encoded body bytes.

The envelope is a claim, never deletion or merge authority. The body digest
detects a stale envelope after a content change; it does not prove lifetime
continuity. NV safe replacement stages an envelope for the resulting bytes.
Missing, malformed, body-mismatched, duplicated, or contradictory envelopes
are unknown evidence, not evidence of creation, restoration, or separation.

### Checkpoint association state

`Notes & Settings` carries a canonical sorted set of incarnation records. Each
record contains one incarnation UUID and the set of note UUID aliases already
established for it. A deterministic representative may be used in a merged
checkpoint, but an existing live note UUID is not rewritten merely because a
different xattr claim arrived. WAL replay and checkpoint merging resolve every
retained alias to the same logical record and preserve all differing bodies.

An association may be admitted only from independently validated
`same-incarnation` evidence. Equal UUIDs, envelopes, filenames, bodies,
timestamps, checkpoint omission, remote File Provider identifiers, or a
completed copyable handshake are insufficient by themselves. No currently
confirmed Apple API supplies this cross-host proof. Until a qualifying source
is specified, independently imported UUIDs remain separate or unresolved.

### Deleted-incarnation state

`Notes & Settings` also carries a canonical sorted set of incarnation UUIDs for
intentional deletions. It is monotonic and unioned across every accepted
checkpoint-current reconciliation. An entry is applicable only through an
already-established association; it never creates an association.

The set does not authorize unlinking a file. Only the original local delete
operation may remove its exact coordinately revalidated file snapshot. A remote
entry may produce automatic logical deletion only when the associated current
file is absent and all normal root, checkpoint, live-note, UUID/LSN, and
generation fences still hold. A present, changed, replacement, copied, restored,
or ambiguously associated file is preserved for ordinary reconciliation or
user confirmation.

## Operations

### Import

1. Read the selected current file and envelope through one coordinated,
   generation-fenced transaction.
2. If an existing association is positively applicable, retain the live UUID
   and update only exact validated association state.
3. Otherwise assign a fresh version-4 UUID and preserve the envelope as an
   advisory observation at most; do not join records automatically.
4. Admit the resulting note and association changes through the existing
   pending-WAL/checkpoint machinery.

### Local intentional deletion

1. Admit the logical deletion and its incarnation into the live store and
   host-local WAL before the exact file-removal obligation can settle.
2. Remove only the captured file snapshot through existing coordinated
   compare-and-swap rules; a mismatch preserves/imports the visible state.
3. Serialize the deleted-incarnation entry in the next complete checkpoint.
   No remote acknowledgment is required before returning control to the user.

### Incoming checkpoint reconciliation

1. Union association records only after validating their pre-existing
   association provenance; conflicting claims remain separate/unresolved.
2. Union deleted-incarnation sets before evaluating note outcomes.
3. Apply a deletion entry only to its established incarnation and only under
   the absence and publication fences above.
4. Preserve delete/edit, replacement, copy, restoration, and unknown-association
   inputs additively. Never filter an unmatched visible file through the deleted
   set.
5. WAL-settle every admitted result before installing the exact-current retry.

### Recovery

Host-local WAL records retain their original note UUID. Recovery consults the
accepted alias records before deciding whether old-UUID and canonical rows are
one logical note. Dropping aliases merely because an xattr or checkpoint chose
a representative is invalid. Deleted-incarnation entries survive checkpoint
replacement by monotonic union; base mismatch alone grants no physical-file
deletion authority.

## User-visible behavior

- A positively associated remote intentional deletion may remove the logical
  note automatically after the corresponding current file is absent.
- File absence arriving before its checkpoint evidence remains an unexplained
  external deletion and follows the confirmation/preservation policy.
- Ambiguous copies, independent imports, safe-save replacements, and
  byte/attribute-identical restorations are preserved rather than guessed.
- An epoch-4 NV ignores the new checkpoint keys and therefore cannot honor or
  preserve these semantics across a mixed-version writer session.

## Costs and limits

- No metadata subdirectory, delivery outbox, receipts, acknowledgments, or
  bootstrap/rejoin protocol is created.
- Every retained UUID costs 16 payload bytes before set/record/archive overhead;
  alias and deleted-incarnation state grows without a proven garbage collector.
- Xattrs may sync in ordinary tested cases but may be copied, stripped, stale,
  or absent from historical versions. They improve identity transport, not
  identity proof.
- A file independently imported before either host accepts the other's
  checkpoint can receive two UUIDs. This candidate does not automatically join
  them without additional same-incarnation evidence.
- An external delete/restore cycle that recreates identical observable bytes
  and metadata between NV observations is fundamentally indistinguishable.

## Required work before adoption

1. Decide whether the conservative independent-import limitation is acceptable
   or specify and validate a real source of positive cross-host association.
2. Specify canonical checkpoint codecs, size limits, malformed-input handling,
   alias provenance, and interaction with encryption and epoch-4 decoding.
3. Extend checkpoint-current, WAL recovery, pending-set, undo, external-edit,
   deterministic-conflict-identity, and startup models with actual alias-bearing
   payloads rather than assuming a `same-incarnation` input.
4. Add integration tests for concurrent first import, xattr write races,
   copy/duplicate, safe replacement, missing/stale envelopes, asymmetric
   file/checkpoint delivery, alias-bearing crash recovery, delete/edit,
   restoration, and competing checkpoint union.
5. Retain negative controls proving that equal/copyable metadata, checkpoint
   omission, or a same-named current file cannot authorize deletion.

Related experimental evidence: [UUID reconciliation experiments](tla/UUID-Reconciliation-Experiments.md),
[incarnation metadata experiments](tla/Incarnation-Metadata-Experiments.md), and
[protocol combination experiments](tla/Protocol-Combination-Experiments.md).
