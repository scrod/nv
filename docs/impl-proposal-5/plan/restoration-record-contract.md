# Fresh-birth Restore record and acceptance contract

Restore implements Recently Deleted recovery in
[Protocol](../Protocol.md#historical-recovery-and-deleted-note-history). It uses
the complete-action acceptance transaction and fresh Create operations, preserving
the source Delete and all prior history. Direct, equal-valued, merged and automatic
prior states retain their exact evidence.

## Canonical representation

`ActionKindV1.restoreBatch` has tag **6**, collection scope, one Create per
affected fresh birth, fresh-absence before states and exact member-value after
states. Following the ordinary affected-state section, encode a big-endian u32
restoration count and entries sorted by resulting birth bytes. Each entry is:

1. Resulting birth: 16 bytes.
2. Source birth: 16 bytes, distinct from the resulting birth.
3. Source deletion action: existing `ActionReference` encoding.
4. Selected source revision: existing `OperationReference` encoding.
5. Optional complete prior state: presence byte 0/1, followed when present by
   the canonical `ActionStateReference` for a derived or automatic state.

The entries cover the restored births exactly once. Restore and Undo/Redo actions
encode this vector; other kinds carry their respective tails from the
[connected record contract](phase3-connected-record-contract.md). Transport references
expand to source action/revision identities for allocated-action comparison;
repackaging changes neither the restored identity nor its provenance. The exact
resulting member is bound through the same birth's affected after-state.

Before acceptance, verify exact reference locations/IDs and source birth/type;
the deletion action is a complete observed group in the writer's causal inputs.
Its affected entry names a complete prior state and a Delete. Each fresh Create
observes that Delete and the selected revision, copies the complete selected value,
and satisfies birth, membership, scope-maxima and origin checks. Default recovery
of a derived/automatic prior state carries that state and every referenced input;
the selected revision belongs to its represented set. A direct prior value uses
presence 0. An explicitly selected retained prior branch also uses presence 0 and
must belong to the source birth's observed history. Other branches remain retained.
Undo of Delete uses the same exact prior-state and deletion-entry bindings.

The independent direct-state action fixture is **202 bytes**, including the
presence byte. Full equal/automatic Restore fixtures in `current-cell-v2.json`
exercise the additional state/reference layout. These are unreleased formats;
no migration from an earlier draft's 201-byte fixture is required.

## Capture and durable indexing

`LocalStoreSession.restoration(from:as:)` resolves a store-issued Delete entry
and returns an immutable `CapturedRestoration`. The host reserves the fresh
birth/generation. `CapturedActionGroup(snapshot:restoring:)` binds one or more
such sources to an exact current authoring context. Retry retains that action,
its births, values and once-sealed bytes. A new explicit command reserves new
identities. Source evidence from another owner/session is rejected.
The `selecting:` overload explicitly chooses another store-issued retained prior
revision. Ordinary full-state recovery preserves the Delete's exact admission
value, including its represented merge inputs.

The `restorations` SQL relation keeps the first accepted restoration action for
each (source birth, deletion action) pair. Insert it in the same transaction as
that action, its complete members and retained closure; subsequent restorations
leave the existing proof intact. Exact result-birth/member/revision mappings
remain in every retained action record. One primary-key lookup plus the action's
first acceptance sequence answers the prefix-scoped list predicate even after
many later copies. Ties within one acceptance batch may use either valid action.
This is accepted-history metadata, reconstructible from exact retained records.
Current-row reconstruction leaves it intact; full index reconstruction repopulates
it through the same validated acceptance path in acceptance-sequence order.

`HistoryQuery.deletions` remains the inspectable retained Delete history.
`HistoryQuery.recentlyDeleted` excludes an entry iff an accepted restoration
names that source birth/deletion action within the listing's captured prefix.
Each bounded metadata chunk filters after reading, so handled entries can
produce an empty page with a continuation. A refresh captures newer history.
The predicate is independent of materialization, callbacks, publication and
whether the resulting birth remains live. Deleting that fresh birth creates a
new entry. Concurrent explicit restorations preserve both births.

General historical copying and compensating Undo/Redo use their separate action
kinds and the same complete-group barrier. Ordinary Create or a generic historical
copy without this exact deletion-entry provenance leaves the entry visible.
Application UI and physical-file installation retain their later integration gates.
