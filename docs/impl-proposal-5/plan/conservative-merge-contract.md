# Conservative merge engine and detached preview

This phase-3 increment implements the plaintext value and note-graph parts of
[Protocol's version-1 merge](../Protocol.md#conservative-automatic-merge-version-1),
HIST-01, ADR 0015 and TC-MERGE-01/02. It prepares the engine and inspectable evidence
and its integration with editable current rows and multi-input action before-states.

## Computation and evidence

`NVConservativeMergeV1` implements the exact scalar, per-label membership and LF
bounding-edit rules. Equality/one-sided body selection precedes the two-sided
line limit. Private `TwoSidedPlainTextMergeInputs` owns three checked token arrays;
the two-sided kernel accepts that type. LF terminators remain part of tokens,
including CR bytes; Unicode, whitespace, NULs and an unterminated last line retain
their exact UTF-8 bytes. Strict separation excludes touching intervals and boundary
insertions. Conflicting fields, over-limit two-sided input or an over-size combined
value return review, while each original value remains valid retained history.

`NoteReductionV1.compute` takes all accepted operations of one birth in a captured
prefix. It checks one creation/import root, same-birth membership and complete
acyclic note-predecessor closure. Its caller supplies accepted membership; these
pure calculations grant no acceptance or persistence authority. It removes
superseded revisions using note predecessors, not causal knowledge. Topological
checking is iterative; two ancestor traversals determine the intersection, and
direct-parent elimination in that downward-closed intersection determines its
maximal bases. No lifetime history-depth cap is added.

- One head supplies a current value. Equal editable head values retain every
  represented ID, the birth's creation date and maximum represented modification
  date. Dates never choose a body.
- Exactly two differing heads and one best common note ancestor form a private
  `EligibleHeadPair`. Only that branch invokes automatic value merging.
- Otherwise the lexicographically smallest head supplies the review preview.
  Its represented set includes heads with the same editable fields; incompatible
  alternatives remain in the complete `heads` result. More than two unequal heads
  are never pairwise folded.
- Any Delete returns `deletionRequired` with its exact IDs. The forthcoming
  collection reducer evaluates all Deletes before publishing source absence and
  any eligible automatic preservation.

`ReducedNoteValueV1` and `DerivedMergeV1` have file-private issuers. A descriptor is
computed only after head/base/value checks, and is distinct from `OperationID`.
Equal-value collapsing retains its input set without inventing a merge operation.

## Derived identity encoding

The fixed identity preimage, concatenated in this order, is:

1. Exact UTF-8 domain `NV derived merge\0v1\0`.
2. Collection ID (16 bytes), then note birth (16 bytes).
3. Policy version: unsigned big-endian u16, value 1.
4. Input count: unsigned big-endian u32, value 2; sorted input operation IDs
   (32 bytes each).
5. Unique best base operation ID (32 bytes).
6. Existing `NoteValueDigest` (32 bytes), covering the complete canonical result,
   including display dates, under its existing value-hash domain.

`MergeIDV1` is SHA-256 of that preimage. The literal fixture and independent Python
construction fix every byte and the input operation IDs. The
[derived-state reference contract](derived-state-reference-contract.md) freezes
the nested equal/merge transport records and exact-target reconstruction.
The [connected record contract](phase3-connected-record-contract.md) integrates
these references into action before-states and private current cells. Merge identity
is independent of the enclosing object and random allocation.

## Runtime preview boundary

`LocalStoreSession.reductionPreview(for:)` captures an accepted prefix, reads one
birth's metadata in chunks of at most 64, and reads exact retained envelopes in
separate database turns. It computes the pure graph/value result off the database
actor, supports cancellation, then checks owner/header/history health again.
New acceptance may advance the store while the returned immutable preview still
describes its original prefix. The preview is presentation data, not a capture,
receipt, physical-file permission or publishable current-row change.

This initial explicit diagnostic/history preview reads the selected birth's full
retained note history and temporarily holds those values. It is not invoked by
healthy startup or ordinary saving. Broad interactive history use still needs
resource qualification and selective value loading; no new persistent graph cache,
schema table, sidecar or automatic merge operation is introduced.

Malformed required envelopes or contradictory accepted membership use the
existing durable history-damage gate. Review outcomes preserve ordinary healthy
history. Closing/cancellation does not modify current values or admitted work.

## Connected runtime consumers

The current/action codecs carry equal and merged states, every represented input,
and incompatible remaining heads. Acceptance reconstructs each declared writer's
complete before-state; ordinary Put/Delete captures exactly Current's represented
inputs. The collection reducer handles Delete coverage, retractable automatic
preservation, independent authored copies and typed retirement. Conflict copies,
historical recovery and causal compensation have their separate action meanings.

The [phase-3 report](phase3-validation.md) records production retained history
→ editable current rows → ordinary edits → both-store fresh reopen, temporary
Current pins and stale generation checks. Detached previews remain read-only
inspection; capture comes from the owned current state. Application UI, Apple
versions and physical projection installation retain their later integration gates.
