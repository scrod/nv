# Equal-value and merged-state references

This contract defines the encoding/validation boundary for the phase-3 matrix's
[M1–M3/A1 gates](phase3-schedule-observation-matrix.md#41-editable-multi-head-state-and-action-capture).
It freezes the derived-state subrecords needed by action before-states and current
cells. The [connected record contract](phase3-connected-record-contract.md) defines
their production writer-history admission, editable materialization and public
edit-capture consumers.

## Canonical layout

Reuse the first-save contract's big-endian scalars, dependency table and operation
references. These are nested value records, not new provider objects or new synced
files. Their containing record supplies collection and birth context. Tags 0–2
remain reserved for the existing absence/single-value/Delete state variants.

| Field | Equal state (tag 3) | Merged state (tag 4) |
| --- | --- | --- |
| Tag | `u8(3)` | `u8(4)` |
| Inputs | `u32(count)` followed by operation references, strictly sorted by expanded operation ID; at least two | `u32(2)` followed by two operation references, strictly sorted by expanded operation ID |
| Algorithm/base | — | `u16(1)` followed by the unique best base's operation reference |
| Result | `Hash32(NoteValueDigest)` | `Hash32(NoteValueDigest)` |
| Derived identity | — | `Hash32(MergeIDV1)` using the existing domain-separated preimage |

Input IDs are unique. The merge base differs from both inputs. External references
carry dependency-table index, operation-section index and expected ID; local
references address only the caller-supplied earlier operation prefix. Construction
sorts inputs; decoding rejects noncanonical input order, duplicates, wrong counts,
unknown policy/tag, trailing data and truncated data. Re-encoding checks the exact
local bindings again, so moving a local index to different operations is an error.
This includes swapping input bindings while preserving their expanded ID set;
the original reference order must still be canonical for the supplied prefix.
Counts and total encoded size obey the existing decoded-payload ceiling.

Transport re-encoding may change dependency indexes/locators while preserving the
expanded state claim. Merge identity includes collection, birth, algorithm,
ordered input IDs, base ID and the full result-value digest, never a locator or
enclosing segment. The result digest includes display dates; the merge reducer
chooses editable fields independently of those dates.

## Reconstruction boundary

`DerivedStateReferenceV1` preserves a canonical claim. Reconstruction:

1. Checks local reference bindings and exact external locator/index/ID resolution,
   including birth/value-kind agreement and membership in the supplied history.
2. Runs the existing note-ancestry reducer over the supplied complete note graph.
3. Compares all represented IDs and the full result digest. A merge additionally
   requires the exact computed base and context-bound derived identity.
4. Issues `ReconstructedDerivedStateV1` through its file-private initializer,
   carrying the computed value and complete head set, including alternatives.

External resolution is asynchronous, matching the existing actor-owned history
lookup path. Each lookup can relinquish database access; the returned records
and supplied graph are immutable values. The final owner/context fence remains
the integration caller's responsibility after reconstruction completes.

The caller supplies the declared writer's complete applicable history. Receiver
Current is not that history. A third head in the receiver does not retroactively
invalidate a merge formed before it; a third differing head in the declared
writer basis does prevent a two-head merge claim. A changed basis must be checked
again before publication. A structurally correct reference cannot establish that
the caller supplied all accepted history, checked an envelope, held physical
ownership or committed a transaction; those existing owner/acceptance fences
remain mandatory at integration.

This reconstruction describes a derived result of the given graph. Temporary
local presentation pins and ordinary single-revision Current keep their separate
capture rules. Equal-value reconstruction retains every represented equal input;
incompatible alternatives remain in the complete head set. Reconstruction emits
no operation, disposition, retirement or Undo action.

## Qualification obligations

- Independent literal equal/merge bytes, including expanded operation identities,
  full result digests and merge identity; round-trip agreement is supplementary.
- Every truncation, trailing bytes, ordering/count/version defects, missing or
  misaddressed dependencies, wrong birth/collection, wrong result/base/identity,
  and local-prefix rebinding. Each semantic negative has a valid graph companion.
- M1's separated LF edits and equal heads, through canonical transport and
  reconstruction; two transport layouts preserve the same expanded state.
- M2's knowledge-versus-predecessor distinction and surviving alternatives in
  the supplied graph; M3's third head, dominating head and ambiguous-base cases.
- File-private construction probes and mutation challenges at the reconstruction
  assertions. Existing action-scope tests remain independent of these subrecords.

These component checks qualify the subrecord boundary. The [phase-3 report](phase3-validation.md)
separately records action/current-cell consumers, saved edits, receipt races and
fresh editable reopening through actual stores.
