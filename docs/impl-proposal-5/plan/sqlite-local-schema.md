# Private SQLite schema: first save/reopen increment

Status: executable schema contract, 2026-09-13. The [DDL](sqlite-local-schema.sql)
is exercised by [real-SQL tests](../../../tests/run-sqlite-schema-contract.py).
The DDL alone establishes neither semantic validity nor durability. The
[Phase 2 Runtime](phase2-local-runtime-validation.md) now uses this exact schema
with complete validation and real SQLCipher/VFS tests. The [Phase 3 connected contract](phase3-connected-record-contract.md)
extends operation/action tags, current-cell codecs and the restoration index for
portable merge/conflict/deletion/compensation commands. It implements the local
acceptance/current-row portion of [LocalStore](../LocalStore.md), using the
[record contracts](first-save-reopen-contract.md#3-first-record-layouts).
The specification, ADRs and causal/file policies are unchanged.

Private revision 3 includes revision 2's [current-row frame/dictionary role](private-current-row-codec.md)
and the derived `actions_conflict_copies(first_seq, action_id) WHERE kind=9`
partial index. This supplies the conflict query's collection-wide copied-version
IDs without scanning ordinary actions. New candidates install it in the versioned
DDL; returning open checks its exact definition and never silently builds an
unbounded index. Otherwise complete revision 1/2 inputs are preserved
with an explicit unsupported outcome; missing required tables/header state keeps
the separate incomplete outcome. This unreleased format has no mixed-writer
promise. Initialize only newly owned candidates. Provider object layouts and
epoch-4 application compatibility are unchanged.

## Scope and physical choices

This increment covers immutable objects, accepted operation/action indexes,
dependency readiness, the retained-history pin, independently versioned private
groups and current-row startup. The packed cache, its delta log, unused per-current-row change sequence and random batch tokens are removed from the design. Dedicated
pending-payload/reservation/settlement tables are now enabled by the
[4C–4E increment](phase4-private-state-repair-copy-validation.md); publication and
projection tables follow with their actual adapters. Keep those reference graphs
queryable rather than hiding them in `private_groups`
as a shortcut. Supported operation/action kinds have complete codecs and validators;
additional kinds require their own validation and schema qualification before
enabling their commands.

Keys retain canonical raw bytes: 16-byte identities, 32-byte hashes, 56-byte segment
locators. Wire unsigned 64-bit sequences use eight-byte big-endian BLOBs, not signed
SQLite integers, strings or floating point. Local batch/group counters are positive
signed 64-bit integers and never wrap. Binary string/value codecs remain Swift-owned;
SQL collation does not normalize bodies, labels or IDs.

`objects`, `current_notes` and `private_groups` use ordinary rowid tables with unique
binary logical keys, keeping potentially large BLOBs out of index B-trees. Small
identity/edge tables use `WITHOUT ROWID`. This is an initial layout, not a claim of
measured optimal locality. Neither rowids nor file offsets become protocol references.
[SQLite layout guidance](https://sqlite.org/withoutrowid.html). No SQL body/title search
index is needed: NV still loads current notes and searches synchronously in memory.
History values are not duplicated into an operation BLOB table; exact envelopes
retain them, and indexed occurrences locate them.

Explicit storage-class checks enforce BLOBs, integral operation/action/rejection
tags and bounded counters; ordinary SQLite
type declarations alone do not enforce these types. The DDL does not require
`STRICT` tables or a system SQLite upgrade. The pinned production SQLCipher build
has the qualification boundaries recorded in the Phase 2 report. [SQLite types](https://sqlite.org/datatype3.html).

## Tables and indexed access

`operations_action(action_id, operation_id)` bounds reverse checks for the existing
deferred action foreign key. The [ordinary-save measurements](current-basis-validation.md)
found a history-sized scan without it. This is an index over existing facts; all
record layouts and schema fields remain unchanged.

`operations_birth(birth, operation_id)` supplies paged per-note history;
`operations_deletions(operation_id) WHERE kind=6` supplies paged logical Delete
entries. Both seek by operation ID under a captured acceptance prefix. This is
stable enumeration, not chronological or causal ordering. Selected previews load
the exact representative envelopes; metadata listing reads no historical bodies.
The scope index supplies complete note-scoped Undo action selection, including
compensation/native coverage. The copy-action partial index supplies global
dispositions, independently of which note is queried. Selection binds to the same
accepted prefix as the checked current capture; selected complete envelopes still
undergo exact occurrence/link/member checks. The deletion index supplies Recently Deleted inputs; the `restorations` primary key
looks up the first accepted restoration for each inspected entry. Exclusion is bounded
to the listing's accepted prefix and survives deletion of the restored birth.

| Tables | Purpose |
| --- | --- |
| `store_header` | Local-store/collection/profile/key/codec/bootstrap binding. Compare with the positively selected owner; these claims are not physical authority. |
| `objects` | Exact immutable bytes and parsed kind/locator. Lookup by hash or full locator; storage is not acceptance. |
| `acceptance_batches`, `accepted_objects` | Object membership in a transactionally assigned local batch. Indexed suffix lookup by sequence avoids reading old BLOBs. |
| `accepted_dependencies` | Complete validated object-evidence edges, including snapshot/descriptor dependencies where applicable. Both endpoints must be accepted by commit. |
| `object_waits`, `ready_objects` | Missing prerequisites and durable unique candidates. Reverse lookup wakes dependents; readiness permits validation, not acceptance. |
| `rejected_objects` | One versioned reason for an exact retained, unaccepted receive object. Rejection and removal of its ready/wait entries share a transaction; its bytes remain in `objects`. |
| `operations`, `operation_occurrences` | One logical operation and all exact accepted object/section-index occurrences. First sequence is local acceptance order, not a cross-Mac clock. |
| `operation_parents`, `note_predecessors` | Separate causal-knowledge and value-supersession graphs, each with forward/reverse lookup. Knowing A and B while replacing A must not replace B. |
| `actions`, `action_occurrences`, `action_members`, `action_scope_parents` | Logical actions, exact occurrences, ordered members and scope ancestry. Origin/predecessor/scope indexes support lazy access; no mutable undo cursor. Null `scope_birth` means collection scope, not unknown scope. |
| `restorations` | First accepted restoration action per source birth/deletion action, committed atomically with complete action membership. Raw action records retain every result/revision mapping and reconstruct this index; current-row rebuild preserves it. One source-key lookup answers the list predicate independently of the resulting note's current existence. See [record contract](restoration-record-contract.md). |
| `retained_frontier`, `retained_descriptors` | Non-disposable required evidence advanced with acceptance. Frontier rows retain full locators independently of object metadata, so a surviving pin still locates missing bytes. |
| `private_groups` | Generation-checked independent settings/association groups. Bounded binary keys are not SQL identifiers or user paths. Only explicitly supported group codecs are usable. |
| `pending_payloads` | Immutable canonical snapshot BLOBs, independently referenced by latest and frozen owners. |
| `pending_items` | Expected-generation latest reference and classification state for each retained external observation. |
| `pending_reservations` | One exact captured reservation per item/snapshot, with reserved birth/action/operation inputs and frozen-payload ownership. |
| `pending_settlements` | Durable observation/committed-identity linkage after matching reference transfer; historical snapshots remain named after payload cleanup. |
| `view_meta`, `current_notes` | Derived current values and compact authoring context through one exact accepted prefix; not every past note value. |
| `current_dictionaries` | Immutable full-digest-addressed zstd dictionary bytes, installed atomically with their referencing derived current cells. Readers load named generations; unused rows can safely remain. |

`source_object`/`source_index` selects an actual representative occurrence. Deferred
composite foreign keys require that occurrence to name the same logical record and
bind its first sequence to the source object's batch. Operation-to-action/member
foreign keys permit insertion within one transaction but reject commit with missing
membership. Additional occurrences do not change the logical record's first sequence.

Do **not** add uniqueness on `(writer_epoch, sequence)`, action origin, or previous
origin action: restored/cloned writers or origins can fork. Preserve exact objects;
causal validation exposes alternatives without picking a winner from an SQL error.
Contradictory content under one canonical identity is instead an integrity failure.

`rejected_objects.validator_version=1` binds the classification to the currently
supported validator. Reason codes 1–7 identify unsupported/ordinary semantic
failures; 20–37 identify the canonical input failures in `ReceiveRejection`.
Unknown versions/reasons require explicit unsupported handling. Missing
prerequisites, transient storage errors and accepted-history damage never become
permanent receive rejections. A future validator upgrade must explicitly reconsider
its retained unsupported candidates. The unreleased schema now requires this table
on returning opens; existing incomplete layouts are not initialized over.

## Initialization and connections

1. Establish exclusive local ownership, unlock and configure the qualified cipher
   before page access. Enable **and verify** `foreign_keys=ON` before transactions
   on each connection; verify the existing WAL/FULL/no-plaintext-spill configuration.
2. Execute this DDL only for a newly created, unselected candidate, within an explicit
   initialization transaction. Insert required header/private/view state transactionally.
   Check commit outcomes, not just prepare/step. Missing headers, partial schemas or
   unknown versions on existing files enter recovery/unsupported handling, not init.
3. The initial view has a fresh epoch and `through_seq=0`, not an editable empty
   collection. Complete Genesis/import/snapshot validation and the independent
   activation gates still precede activation. Header or descriptor presence alone
   does not satisfy bootstrap completion.

There is no `CREATE ... IF NOT EXISTS` repair-by-initialization or `INSERT OR REPLACE`
identity update. Duplicate arrivals first compare existing bytes; object triggers
reject updates/replacements. Accepted history/index rows use insert-only writer
paths; normal operation never deletes them. The future adapter must encapsulate SQL
access, including forbidding identity-table upserts. DDL does not protect against
arbitrary privileged SQL or damaged pages. No published segment schema needs migration
yet; later versions require reviewed transactional migration or validated sibling
rebuild, not opportunistic ALTER statements at each open.

Deferred-constraint failures can occur at commit. Roll back, retain admitted RAM
state and acknowledge nothing. I/O/busy failures retain the existing ambiguous-
completion policy: finish recovery and query exact identities rather than assuming
success or rollback. [Foreign keys](https://sqlite.org/foreignkeys.html),
[transaction completion](https://sqlite.org/lang_transaction.html).

## Receive, park and accept

**Retain.** Bound/hash/check the available envelope structure and scope outside the
writer transaction; authentication/semantics may still require missing evidence.
Compare existing exact bytes; insert a new object and ready entry together. Duplicate
scans do not blindly requeue permanently invalid/unsupported input. This first
increment does not enable a receiver for unknown outer formats: leave their source
untouched and report unsupported, never coerce them into a known `kind`. Complete
provider-receive quarantine storage remains a later feature gate, not permission
to discard existing evidence or add another private file store. An expired retry
budget is not permanent invalidity.

**Park.** Keep queue ownership in memory while validating; do not delete the durable
entry on dispatch. In one writer transaction replace the captured missing-prerequisite
rows and recheck current accepted membership. If any captured missing prerequisite
is now accepted, keep/requeue the candidate: a parent may have committed after the
worker's read. Otherwise remove its ready entry. The next validation parks only on
still-unsatisfied evidence, avoiding a satisfied-parent retry loop. Missing endpoints
intentionally have no prerequisite foreign key in `object_waits`.

**Accept one prepared unit.** Core first validates authenticity, exact references,
complete action agreement and scope. Fresh creation validates its complete bootstrap
unit; do not create a circular key/Genesis wait by treating unlocking availability
as an operation-causal edge. Then under the serialized writer:

1. Recheck owner/store scope and captured accepted prefix `H` under the same live owner/lifecycle generation. Resolve
   every prerequisite to already accepted evidence or another fully validated member
   of this unit. Do not replace unrelated settings from an earlier capture.
2. Filter exact already-accepted objects. An entirely duplicate unit gets no new
   batch. A **new envelope containing known operations** needs acceptance/pin coverage
   and a new object batch, but no new logical operation/action or repeated mutation.
3. Allocate `H+1` **once per transaction**.
   Insert new object membership, complete record/occurrence/edge indexes and exact
   dependency edges. Compare duplicate logical records by fully expanded canonical
   semantics; transport bytes can legitimately differ.
4. Advance required descriptor/maximal-segment pin rows from validated dependency
   history, never sequence or current-note presence. `accepted_object_ready` removes
   accepted objects' wait/ready rows and requeues dependents in this same transaction.
   Deferred prerequisites must all exist by commit.
5. Commit before acknowledgment, incoming live publication or eligibility for any
   external effect. Exact identity recovers without a callback. A future pending-
   import observation link joins this **same** transaction, not a callback write.

The trigger wakes on *any* accepted parent; accepting the child still requires **all**
parents and exact referenced members. Wait rows contain abbreviated scheduling keys;
complete references remain in immutable bytes. For example, resolve an external
operation using the full captured locator and section index, not any convenient
occurrence of the same operation elsewhere:

```sql
SELECT o.encoded
FROM objects o
JOIN accepted_objects a ON a.object_id = o.object_id
JOIN operation_occurrences r ON r.object_id = o.object_id
WHERE o.object_id = :segment_hash AND o.writer_epoch = :writer_epoch
  AND o.sequence = :sequence_be64 AND r.record_index = :index
  AND r.operation_id = :expected_operation;
```

## Materialization, settings and reopen

Query `accepted_objects WHERE seq > :viewThrough` and `operations/actions WHERE
first_seq > :viewThrough`, bounded by the captured target, for newly accepted objects
and newly introduced logical records. All are indexed suffix queries. An old parked
object's later acceptance appears even though its bytes predate the view. A new
occurrence is evidence, not a new effect. Descriptor/snapshot-only batches still
advance the exact represented prefix.

A separate guarded transaction updates changed current cells, removes logically
absent rows, updates global authoring context and advances `through_seq`. Body-equal
changes can still change context. The writer enforces `0 <= viewThrough <= H` and
exact reduction through that prefix; a foreign key does not prove a row's value or
scope frontier. Materialization failure leaves acceptance intact and is retried
before editable publication. No O(total history) healthy-startup pass is introduced;
known damage, invalid-materialization rebuild and fresh bootstrap keep their existing
separate recovery costs.

Returning startup scans `current_notes` in table order (`ORDER BY rowid` if explicit
ordering is needed), not UUID-index order. The UUID index serves keyed mutations
and lookups. Decode directly into unpublished note/context storage without a second
whole-collection encoded buffer; complete capture/search initialization and the
existing final generation fence still precede publication. This preserves the
single consistent read transaction, not independent per-note read snapshots.

Private updates are scoped to one group's expected generation:

```sql
UPDATE private_groups SET generation = :next_generation, payload = :captured_payload
WHERE group_key = :key AND generation = :expected_generation AND codec = :codec;
```

Require exactly one changed row; check `next = expected + 1` without overflow. A stale
aggregate never overwrites unrelated groups. The headless caller supports empty
settings codec 1 and bounded nonempty codec 2 from the
[private-record contract](private-record-contract.md). Platform interpretation and
legacy preference migration remain the host's responsibility.
Required state codec failure is not merely derived-row damage or permission to erase that group.

The required `bootstrap` group has codec 1. Its empty payload records a newly
owned construction whose initial root has not yet been chosen. A nonempty payload
is exactly the canonical `SegmentLocator` of the selected initial root. Choosing
it increments this group's generation transactionally; retries compare the same
root. Staging this address is separate from accepting complete bootstrap history.
Ordinary opening requires the selected root and complete committed evidence.
`BootstrapCandidate.resume` may reopen the positively selected incomplete candidate
with the existing store/descriptor/profile checks. S3 adds these staged semantics
within the existing group codec and schema; it adds no table or on-wire field.

Protected accepted-history checks commit a versioned request in `private_groups`
before inspecting retained evidence. Admission uses its existing unique-key index
and allows at most 64 outstanding requests; a full range returns `busy` before the
check starts. Nested reads share a covering request. Exact settlement removes only
the completing request, after final graph/reducer checks.

| Verification field | V1 encoding |
| --- | --- |
| Group key | UTF-8 `verification/` (13 bytes), then fresh 16-byte verification identity |
| Group generation / codec | `1` / `1` |
| Payload prefix | `NVVRFY1\n` (8 bytes) |
| Bound context | LocalStoreID (16), CollectionID (16), descriptor digest (32) |
| Exact-object recipe | Tag `1`, then SegmentLocator (56); total payload 129 bytes |
| Accepted-prefix recipe | Tag `2`, positive signed-range UInt64 big-endian prefix; total 81 bytes |
| Bootstrap recipe | Tag `3`, then SegmentLocator (56); total payload 129 bytes |

Unknown codecs/tags return `unsupported`; malformed lengths, generations or bound
context return `integrity`. Missing named accepted scope returns `incomplete`.
[Independent byte fixtures](phase-4-improvements/verification-fixtures.json) and
`tools/check-verification-fixtures.py` freeze these private layouts. Decoded
records become replay requests; connection-bound admitted handles and successful
completion values have restricted issuers.

Discovered accepted-history damage immediately blocks the session. The owner then
attempts an independent transaction inserting `history-damage` (exact UTF-8),
generation1, codec1, empty payload, and removing the affected verification request.
At most one diagnosis attempt occurs per actor turn; a later turn may retry. Either
the request survives or the marker commits. Presence of that marker requires repair
on reopen. Invalid incoming claims and transient failures retain their distinct
classification. Reopening repeats pending exact requests before publication;
retained framing failures are reported as recovery `integrity`. One automatic
live replay may settle a transiently interrupted check; another failure leaves its
request for explicit retry/reopening, preserving bounded retry behavior.

This records observed/unfinished checks, rather than certifying every unread byte.
Qualified repair of retained evidence remains the authority for a healthy replacement.
Backups include requests; fresh-store repair must prove scope equivalence before
rebinding an original store's prefix.

## Boundaries of SQL enforcement

| SQL checks | Still required in the validated writer/opener |
| --- | --- |
| Binary widths/types, enum/count bounds, uniqueness | Hashes, AEAD, decoded limits, supported versions and correct metadata extracted from bytes |
| Accepted dependency endpoints exist by commit | Every actual reference was included; exact locator/index/type/ID agreement and semantic closure |
| Operation/action membership and representative occurrences exist | Every complete action's members occur in each claiming envelope; contiguous ordinals/indices and exact before/after/kind/scope agreement |
| Edges reference existing records and are not self-edges | Longer-cycle rejection, same-birth predecessors, scope maxima, origin provenance and distinct graph meanings |
| Pin endpoints exist and locator embeds the hash | Complete required descriptors and exact maximal segment locators; no pin regression/pruning |
| Atomic visibility and rollback | Owner/generation fences, no early acknowledgment, correct reduction and qualified physical durability |

SQL cannot discover a reference a buggy decoder omitted or prove that a materialized body
follows from an authentic operation. Do not describe these constraints as a complete
NV history validator.

## Validation and next gate

Run `make -C tests run-sqlite-schema` (Python stdlib/SQLite; no Cocoa build). Tests
read this exact SQL file, using conspicuously synthetic **non-wire** bytes. They cover
type/bound/FK rejection, writer forks including UInt64.max, duplicate objects and
occurrences, independent causal/predecessor edges, operation lookup after logical
deletion, missing representative/member/parent rejection, multi-parent readiness
and stale parking, rollback of wakeups, consistent readers, independent settings/
materialization, indexed query plans, and child-process exit before/after commit.
A disabled-FK negative control confirms that an independent integrity check finds
the forbidden orphan.

Executed on 2026-09-14: **17 schema tests pass** on SQLite 3.53.4, including both abrupt-exit boundaries. The current-row [fast-start SQL checks](sqlite-fast-start-validation.md) pass 21 named checks using this DDL. These use ordinary SQLite with synthetic contents, not encrypted production pages or genuine NV history. The [transaction validation](sqlite-collection-transaction-validation.md) separately records compiled crash and model coverage.

The [SQLite transaction model](../../tla/README.md#private-sqlite-transaction-and-fast-start-mapping)
supplies surrounding crash/ready/acknowledgment obligations, not proof of this DDL or
arbitrary action decoding. Cache removal updates the surrounding models to current materialization; it does not change immutable-history or file-authority requirements.
Before production, run these cases through the Swift writer with real decoded groups
and the pinned SQLCipher/VFS. Put equality/closure/pin checks at the shared author/
receive/bootstrap/repair entrypoint. First-subset action/payload framing, group
consistency and exact direct-reference checks now exist in `NVStorageCore`; see the
[implemented boundary](first-save-reopen-contract.md#implemented-action-and-payload-boundary).
They do not authorize acceptance. The [Phase 2 adapter](phase2-local-runtime-validation.md)
now performs bootstrap/ordinary validation, exact authenticated object binding,
acceptance and current-row recovery over this DDL. Later reducers, repair/activation
and scheduling qualification remain gates; adding every future table is not the
next step.
