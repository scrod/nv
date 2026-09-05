# Private SQLite storage and fast startup

Status: adopted local-storage contract; packed cache removed 2026-09-14. The
[Phase 2 Swift Runtime](plan/phase2-local-runtime-validation.md) implements the
ordinary local subset; general reducers, platform and application integration
qualification remain outstanding. This replaces the separate
private object/pending/state **file layout**, not the immutable provider
format or the causal, deletion, undo and physical-file rules in [Protocol](Protocol.md).
The [transaction experiments](plan/sqlite-collection-transaction-validation.md)
establish a narrower executable foundation, not a production implementation.

## Current rows, not a packed startup cache

The [equivalent-load benchmark](plan/remaining-storage-validation.md#startup-remove-the-packed-cache)
found no meaningful benefit from maintaining a second packed current-state
representation. **The packed startup cache is removed from the design**, not
deferred as an optional format. Returning launch reads indexed current-note rows
and compact authoring context from the private database.

That comparison used fresh rows. The [aged clean-exit follow-up](plan/aged-current-row-startup-validation.md)
finds a significant physical-locality regression and shows that ordinary table
rewriting is not an unconditional cure when scattered free pages are reused.
The [clean-quit locality candidate](plan/clean-quit-locality-strategy.md) now tests
smaller current cells and bounded read-ahead from a saved physical page list,
including fragmented freelists and less-compressible text. It improves launch
without a table rewrite; it is not a frozen codec/cipher profile or a production
hint protocol. Table-order streaming is required below, but packed-equivalent
cold performance is not established for every aged layout. The
[opportunistic full-VACUUM policy](plan/clean-quit-locality-strategy.md#adopted-opportunistic-full-vacuum-policy)
is adopted, subject to scheduling and safe-interruption qualification; no
mandatory quit rewrite/VACUUM or packed format is adopted. Any eventual read-ahead hint remains
disposable I/O advice, never current values or evidence of represented history.
The user-selected tuning for that candidate is now **zstd level 3**, training
from at most **1,024 candidate current notes / 8 MiB** into an **8-KiB dictionary**;
see [bounded dictionary tuning](plan/clean-quit-locality-strategy.md#bounded-dictionary-tuning-selected-for-the-candidate).
These budgets never limit which notes are saved. Automatic all-row rewriting
and the production physical codec/adapter remain qualification work, not new
quit prerequisites.

Provider snapshot roots/pages remain immutable `NV Data` history objects used
notably for initial-import/bootstrap verification. Their authentication alone
does not establish semantic correctness or dependency closure. They are not a
remote shortcut into the private current materialization.

### Consequences of removing packing

| Remove | Retain, and why |
| --- | --- |
| `StartupCacheV1`, packed payload/header/digests and cache-compression worker | Canonical current-cell and authoring-context codecs; every current note must be reconstructed correctly. |
| `startup_cache`, `view_changes`, per-row `changed_seq`, cache epoch, delta floor and pruning | Indexed acceptance batches and `viewThrough`; accepted history can outpace derived current rows, including parked objects becoming applicable later. |
| Random acceptance-batch token used to bind a packed cache to a restored branch | Positive store ownership, view epoch and lifecycle generations; all current rows/context are captured from one database read transaction, never transplanted by matching a numerical prefix. |
| Background cache construction, certificate validation and cache publication/quit step | Atomic materialization and final startup publication checks; a stale worker must not publish old values or context. |
| Cache-miss/fallback states and cache-only resource limits/format work | Exceptional materialization rebuild and required-store repair; derived data cannot conceal known retained-history loss. |

SQLite transactions do not prove that reduction produced the right current
values. Independent reducer/row-decoder tests, complete context updates (even
when bodies are equal), and exact deletion handling remain required. The
retained-history pin, required private state, encryption/key lifecycle, backup
and source-preserving repair are unchanged: the database still contains unique
data. Current values, settings and retained pending previews still require
private-page protection under the chosen key policy; sealed history BLOBs alone
would not protect them. Provider envelope compression, snapshot formats, key
domains and SQLite's own pager cache are unaffected.

## Container, ownership and durability

All new compressed private records use zstd, with codec and dictionary metadata
owned by their local record format. SQLCipher supplies page encryption, not
compression; provider envelopes retain their separate dictionary-free
[zstd profile](Encryption.md#compression-profile). Uncompressed canonical current
cells remain the Phase 2 correctness baseline while the selected dictionary
optimization is qualified.

One `Collection.sqlite` per `localStoreID` holds exact retained object bytes,
required private state, indexes and current-state materialization. SQLite's
`-wal`, `-shm` or rollback journal are private
transaction machinery, **never** synchronized NV journals. `NV Data` still
contains the identical immutable provider envelopes and descriptors.

Use the existing exclusive local owner and positive store/root association.
One serialized database writer belongs to that owner; detached workers prepare
validated immutable inputs, not independent writers. Use short write transactions;
never hold one across provider access, an `await`, text processing or UI work.
Optional idle full VACUUM is the qualified physical-maintenance exception to
short ordinary writes, not to exclusive ownership or timely local durability.
It must yield to required persistence under the linked maintenance policy;
running on a worker does not remove SQLite's single-writer constraint.
Separate reader connections use explicit read transactions for consistent
multi-query captures. Startup's read transaction may decode current cells directly
into the final, still-unpublished note/context storage; it must not wait for provider,
history-UI or editor work. Finish the capture and close that reader promptly rather
than retaining it for the lifetime of the loaded model. [SQLite isolation](https://sqlite.org/isolation.html).

Production uses encrypted database pages for **both** collection profiles,
including indexes, pending buffers and current values. Opening supplies an opaque
validated database key; SQLCipher does not change the provider encryption format.
The key policy below distinguishes password-free recovery from remembered
encrypted unlocking. The pinned cross-platform SQLCipher build and production
credential implementation remain release gates. See the measured
[SQLCipher qualifications and rekey warning](plan/sqlcipher-validation.md).

Configure and verify `foreign_keys=ON`, WAL mode and `synchronous=FULL` on the
writer; disable memory-mapped database access and plaintext spill paths. Qualify
the platform VFS's durable-sync behavior (including the stronger macOS sync
configuration) rather than treating process-kill tests as power-loss proof.
Use bounded readers and a nonblocking checkpoint policy; a reader can prevent
WAL truncation. WAL checkpoint failure cannot retract an already committed edit.
Never copy just the main database while its journal is live: use a consistent
SQLite backup or a quiesced complete-store copy. The database contains required
history and must not be marked purgeable or backup-excluded just because it also
contains rebuildable current rows. [SQLite WAL](https://sqlite.org/wal.html),
[sync settings](https://sqlite.org/pragma.html#pragma_synchronous).

`COMMIT` is the local durability barrier after successful validation and the
qualified sync configuration. A failed or lost completion is ambiguous: reopen
or finish recovery, then query the exact operation/object identity. Do not reseal
different bytes under the old identity, repeat a user action, or acknowledge from
a reservation alone. Contradictory bytes under an existing identity are an
integrity failure, never an upsert.

## Database keys and password-free recovery

Use the existing collection-key lifecycle, not a second random device secret,
database-password preference or database-key wrapper protocol. The raw 32-byte
SQLCipher key is:

```text
PlaintextFilesV1:
  SHA256(ASCII("NV public local database key\0v1\0"))
EncryptedSegmentsV1:
  HKDF-SHA256(IKM = CK, salt = collectionID || keyID,
             info = ASCII("NV private database key\0v1\0"), L = 32)
```

UUID inputs are their raw 16 bytes. Neither path, local-store ID, machine identity,
Keychain item nor mutable password participates in derivation. SQLCipher still
generates and retains its own random database salt. This deliberately allows a
fresh local store for the same encrypted collection to derive the same raw key;
database-header checks and exclusive physical ownership, not key uniqueness,
establish local-store association. The database derivation domain is different
from every provider-object key domain.

Pass the key using SQLCipher's documented raw-key syntax through `sqlite3_key`;
32 arbitrary binary bytes supplied directly are not that syntax. Configure the
pinned cipher profile before the first page read. A successful key-setting call
is not verification: read and validate the database's required header and scope.
[SQLCipher key API](https://www.zetetic.net/sqlcipher/sqlcipher-api/#key).

For **password-free** collections the key is public protocol information. A
consistent database backup remains readable without Keychain, the original Mac,
its folder name, the provider, or a separate key file. Restrictive filesystem
permissions still apply, but SQLCipher pages provide no secrecy from a reader of
the file. Do not describe this as password protection. Losing auxiliary selection
metadata requires re-association, not a secret-recovery prompt. A positively
pinned encrypted collection must never fall back to the public key/profile.
Explicit recovery of an otherwise unassociated public database may inspect its
contents; successful opening does not authorize provider/file writes.

For **encrypted** collections, retain outside the encrypted database exact copies
of the existing bounded wrapped-key descriptors, under their content-hash names
in the private store's `unlock/` directory. They contain no clear CK, database key,
password or device reference. Validate their format and authenticated bootstrap
binding after password/recovery-key unlocking, then compare the database header's
collection/key/profile with the selected bootstrap. This directory is only an
unlocking aid, not another history store. Its loss can be repaired from matching
`NV Data`/backup descriptors or an already usable CK; no SQLCipher file is declared
corrupt merely because its password/descriptor is unavailable. A private backup
must carry usable descriptors so provider loss does not also prevent unlocking.

Password change reuses the existing same-CK descriptor protocol:

1. Capture the current collection/key/bootstrap under ownership. Prepare a new
   Argon2id/AES-GCM descriptor; never replace or delete the old descriptor.
2. Exclusively install and durably read back the exact new `unlock/` descriptor.
   Unwrap it with the new password and verify the pinned bootstrap/key. Failure
   leaves the old route and database untouched.
3. In one database transaction retain those same descriptor bytes, accept their
   validated same-key association and enqueue publication. Only then report the
   password change saved locally; provider publication remains asynchronous.
4. On uncertain completion query the exact descriptor identity. An orphaned
   valid external descriptor can be reconciled idempotently; an old backup still
   has its old route. Never retire an old usable descriptor/credential to infer
   that the new password has propagated. Old passwords may continue unlocking
   retained copies, as already disclosed by the provider policy.

Remember on this Mac caches CK for an **encrypted** collection and remains
optional; forgetting/resetting Keychain cannot destroy its password route.
There is no routine native database `rekey` or separate database-key cutover.
Changing the provider encryption profile/key still uses the existing fresh
destination conversion; this does not introduce an in-place full-history
conversion or a second local password switch. A password-only change leaves
history and current-value pages alone, apart from normal descriptor bookkeeping.

## SQLite backup, salvage and replacement activation

**Independent evidence.** Concretize the required active-association cutover as a
small selected-store record, `Collections/selection-<associationID>.nvlocal`,
outside either candidate database. It holds a format version, the independent
association ID, selected local-store ID, fresh selection generation and checksum;
no notes, secrets, paths or history frontier. Its bounded canonical encoding and
durable expected-generation replacement need adapter qualification. The
[90-byte selected-record codec and recovery-key format](plan/remaining-storage-validation.md#recovery-artifacts)
now have independent fixtures and rejection tests; they do not implement activation. It is a
locator to revalidate, not root authority or a history watermark. Exact unlock
descriptors are the only additional required encrypted bootstrap copies outside
SQL. The accepted-history pin remains in the same transaction as acceptance:
there is no per-edit sidecar frontier or second journal. Loss of the selection
reference leads to explicit re-association; loss/rollback of the database and all
independent history evidence cannot reveal the erased accepted frontier.

**Complete private backup.** Briefly fence descriptor/association changes and
capture a fixed SQLite read transaction on a separate keyed connection, including
its scope/prefix and required descriptors. Release the capture fence before doing
bulk work; ordinary local writes continue. Use the SQLite backup API from that
snapshot into a newly created, correctly keyed destination database, not a copy
of the live main file. Step it with bounded work; bound the retained reader/WAL
resource cost and cancel/retry backup rather than suspending typing. Copy all
applicable exact unlock descriptors and verify the captured scope, retained pin
and required private state in the destination before marking the backup complete.
The result covers its captured durable state, not uncaptured RAM edits or changes
admitted afterward. Active-session recovery/export still drains admitted work
under its existing policy before claiming to have saved it. Release the
reader/fence on every outcome. A quiesced copy of the complete database and any required
journal is an alternative for external backup tools, not permission to omit a
live WAL. Reopen checks include the captured acceptance prefix, settings, pending
latest/frozen payloads and their links—not just visible notes or derived rows.
[SQLite backup API](https://www.sqlite.org/backup.html).

**Damage handling.** Suspend new admission; preserve live/admitted buffers.
Quiesce every connection and preserve the original database and its WAL/rollback
journal as one evidence set before recovery attempts. Do not remove a hot journal,
checkpoint damaged originals, run VACUUM, repair in place or start an empty DB
over the old name. Recovery that can write SQLite journal state runs on a complete
working copy. Unreadable evidence that cannot yet be copied stays untouched;
inaccessibility is not proved loss. Wrong/unknown credentials and unsupported
cipher settings are separate diagnostic possibilities, not inferred corruption
from `SQLITE_NOTADB` alone.

Build a fresh sibling `localStoreID` using the common repair union:

1. Salvage independently readable exact object/descriptor BLOBs from the working
   copy and available provider/backups. Recompute identities, authenticate where
   applicable, decode with bounds, and validate complete dependencies/actions
   before acceptance. Query independent known identities/ranges after a damaged
   row; a page/codec error can leave the connection's codec in an error state, so
   reopen a fresh keyed working-copy connection before independent salvage reads.
   One failed scan is not proof that every table/row is lost. SQLite recovery
   output is only candidate data: it may violate constraints or contain formerly
   deleted or never-committed rows. V1 salvages through normal SQL reads of a
   journal-recovered working copy. Low-level recovery output without committed
   provenance remains quarantined unless independently matched to a validated
   committed copy; valid bytes alone do not prove a local action committed.
   Do not trust recovered acceptance flags, keys or current rows as history.
   No custom damaged-page parser is required for v1.
2. Preserve readable required private settings and latest/frozen pending payloads,
   reservations and exact operation links. Validate each complete record group
   and reference graph. A partial group is quarantined evidence, not replayable
   consent. Recover completion by exact accepted operation identity; otherwise
   require fresh review/association. Never regenerate lost pending text from
   provider history or replace an admitted snapshot with a newer preview.
3. Verify coverage of the surviving required pin and every known unique local
   object, unpublished edit and pending payload before claiming complete repair.
   A pin can reveal a gap, not supply its bytes. Missing required history blocks
   ordinary activation; only another copy or explicit current-state salvage can
   proceed. Missing private-only state is reported separately; do not silently
   discard known pending work. If all evidence of that state was destroyed,
   fresh-Mac recovery cannot claim to have recovered it.
4. Rebuild derived acceptance/current indexes from validated history; preserve
   exact object identities/bytes, but allocate new local batch/view identifiers.
   Commit the new association, pin and validated private records transactionally.
   Reopen/verify the candidate with its recovery credentials, not a remembered
   live handle. No old file receipt, reservation or consent becomes current
   physical authority; re-observe root/files before external effects.
5. Under the same exclusive owner of the selection and both store candidates,
   recheck the captured selection/store generation
   and atomically durably replace the existing selected-store reference with the
   new identity. This is the sole activation point, after the verified DB and its
   unlocking routes are durable. Before it, restart selects the old store/repair;
   after it, restart verifies the new one. Ambiguous completion reads back the
   reference; it never guesses by newest filename or deletes either candidate.
   Open fresh writer/action origins. Root loss meanwhile still fences external
   effects; a complete local repair can remain useful offline.

An incomplete candidate is never activated as a complete store. If it is impossible
to preserve or validate required state, retain the old evidence and follow the
existing explicit recovery/export choices. Settings that truly cannot be recovered
may start fresh with disclosure; they cannot authorize abandoning retained pending
contents. Once a complete local store is active, it can transparently repair
positively owned local `NV Data` damage under the existing root/generation rules.
There is still no Restore NV Data button or generic Work Offline error mode.
[SQLite recovery limitations](https://www.sqlite.org/recovery.html).

## Logical schema and transaction boundaries

The [first save/reopen schema](plan/sqlite-local-schema.md) supplies executable
DDL and SQL constraint/transaction tests for the initial history, ready-work, pin,
private-group and current-row roles below. It uses current-row startup. Pending/projection feature tables and later record codecs remain work;
the schema is not a complete Swift storage adapter.

The following roles are required, regardless of later query-driven index tuning.
Canonical record bytes and identities use the existing Swift/wire contracts;
SQL row IDs and local sequences never become causal or transport identities.

| Role / key | Retained fields and constraints |
| --- | --- |
| Store header / singleton | Schema/reducer/materialization versions, local-store and collection identities, profile/bootstrap association. Opening validates these against the selected owner, not vice versa. |
| Objects / exact object identity | Exact immutable envelope/descriptor BLOB, kind and bounded length. Received/parked bytes are distinguishable from accepted objects. All references resolve by validated identity, never an embedded path. |
| Dependencies / dependent, prerequisite | Indexed reverse lookup by prerequisite; covers external segment/operation/action/descriptor prerequisites. Internal references are validated within their complete object. Missing and unsupported prerequisites are not acceptance. |
| Ready work / object identity | Durable, unique validation/acceptance candidates. Store eligible arrivals here; prerequisite acceptance requeues affected parked objects in the same transaction. Validation may discover another prerequisite and park again. Known actionable work must not depend on an in-memory callback. |
| Acceptance batches / positive local sequence | Exact newly accepted object/record membership. One transaction assigns the next sequence; duplicate acceptance assigns none. This private index orders materialization catch-up, not causality or cross-store identity. |
| Accepted records and occurrences / canonical ID, object location | Complete operations/actions, causal/predecessor/scope edges and exact source locations. Duplicate occurrences remain one logical record; inconsistent records fail. Index all referenced kinds, not only note edits. |
| Retained-history pin / current required frontier and descriptors | Advanced with acceptance. Names the retained evidence required by this store; no upload flag or derived view replaces it. Known missing/corrupt evidence blocks complete recovery. |
| Local State / independently updated field or versioned group | Settings, association, pending publication/projection work and generation-bound observations. Update only the affected current group; no stale aggregate settings replacement. |
| Pending payloads / snapshot identity | Immutable bounded captured bytes, latest references and separately owned frozen operation references. Replace payload and latest reference in one transaction; only unreferenced payloads can be released. |
| Reservations and receipts / admitted observation and operation identity | Exact captured input plus fresh birth/action/operation IDs; receipt settlement and link transfer share a transaction. A reservation is not replayable consent; committed operation membership, not live-note existence, establishes completion after restart. |
| Current materialization / live birth | Complete current value and compact validated authoring context through `viewThrough`. Includes the references/frontiers needed to author an ordinary edit without a full-history read; not every past value or undo index. |

Two transactions have deliberately different failure consequences. Keep this split
after removing packing: causal reduction can lag without delaying or retracting
the local history barrier, and indexed catch-up restores the current view:

1. **Accept history.** Prepare exact bytes and full action/dependency validation
   outside the write transaction. Recheck the captured store/history generation;
   atomically insert the new objects/accepted records, batch membership,
   pin advancement, ready work and any admission/observation linkage. Only then
   acknowledge durability or make provider/projection work eligible. Parent
   acceptance and requeueing all affected dependents are inseparable. A ready
   candidate is revalidated before acceptance, including all its parents, not
   merely the parent that woke it. No partially accepted action group is visible.
2. **Advance the materialization.** Reduce the indexed accepted suffix from
   `viewThrough` using existing causal rules and lazily accessed graph evidence.
   Recheck the captured view epoch/prefix; atomically update affected current
   rows, global authoring context and `viewThrough`.
   Deletion removes a current row in that same transaction. A metadata-only
   frontier change counts even if its displayed body is unchanged. This derived
   transaction may lag accepted history; its failure does not undo acceptance.
   It must catch up before an editable startup result is published.

Pending retention/reservation and physical-receipt settlement use their own
generation-checked transactions from [the pending protocol](Protocol.md#pending-file-retention-and-retry-identity).
The DB does not atomically commit a filesystem effect. Fresh rooted file evidence
and final operation-generation checks still govern physical association,
replacement and Apple disposition. A receipt is historical evidence, not an
accessor or delete capability surviving restart.

## Current-view invariants

Use the [executable schema](plan/sqlite-local-schema.sql), not a second
startup-specific schema. The owner enforces
`0 <= viewThrough <= acceptedThrough`, a complete prefix of local acceptance
batches, and current rows/global authoring context representing **exactly**
`viewThrough`. A batch may affect no live birth and still advance context.
Initial-import completion precedes ordinary editable startup. Local signed-64-bit
counters never wrap; exhaustion requires a controlled store/index rebuild under
ownership.

A materialization rebuild allocates a fresh view epoch. Workers captured against
the old epoch cannot install rows or publish a startup model, even if the
numerical prefix happens to match. Store selection and lifecycle checks remain
independent of the epoch; neither sequences nor database contents authorize
access to a physical repository.

Current cells include the revision, note-predecessor and action-scope references
needed for ordinary editing, not every past body or undo index. Freeze their
canonical bytes and independent vectors with the corresponding Core records.
SQLCipher authenticates accessed pages, not semantic reduction or every unread
history page. No digest of a decoder's own output supplies that missing proof.
Local continuity cannot expose an undetectable rollback of all copies and
independent evidence.

## Concrete returning-launch algorithm

1. Establish exclusive local ownership, selected association and unlock; let
   SQLite recover its journal. Validate required header/schema/private state and
   any **known** missing/corrupt retained-history evidence. Wrong credentials,
   required-state damage and unsupported history require explicit failure/recovery
   classification.
   A live session detecting invalid accepted-history bytes immediately revokes
   prepared publication. The private [known-damage marker](plan/sqlite-local-schema.md#materialization-settings-and-reopen)
   retains that observation across reopen when its transaction can commit. Invalid
   incoming objects do not poison otherwise healthy accepted history. Failure to
   record the marker never re-enables the live session; interruption before commit
   remains a separate recovery/physical-failure qualification boundary.
2. Hold the owner's startup admission/publication fence: no UI mutation or new
   provider acceptance may move the final startup target. Provider discovery can
   remain independent; do not wait for cloud completeness. Drain the durable
   ready queue with normal validated acceptance until no currently actionable
   local candidates remain. Park genuinely missing prerequisites. This includes
   previously parked objects whose parents arrived later.
3. Bring the materialization through the indexed accepted suffix to the resulting
   stable `H`. Required graph reads follow exact dependencies/indexes; no scan of
   all old object BLOBs, operations or action records is part of healthy startup.
4. In one read transaction at `H`, capture store scope, reducer version, view
   epoch, `viewThrough`, all current rows and global authoring context. Strictly
   decode/validate the complete cells and their compact frontiers; do not silently
   skip malformed rows. No separate packed representation or changed-birth log
   is read. Traverse the current-note table in table/rowid order, not through its
   UUID index merely to obtain a canonical load order. Rowids are local traversal
   details, never identities or presentation order. Decode each cell into its
   final unpublished note/context storage before advancing the statement; do not
   concatenate rows into a whole-collection encoded buffer or retain duplicate
   cell BLOBs solely as an intermediate startup representation. Bounded temporary
   decoding storage is permitted. SQLite-owned column pointers must not escape
   their valid statement lifetime. Build only from this consistent captured state.
5. Construct the full in-memory note/search model. Before main-thread publication,
   recheck the owner/store/lifecycle generation, view epoch and `H` against both
   accepted and materialized prefixes. A changed target requires catch-up, not
   publication of an editable stale model. Then enable immediate synchronous
   input/search and release the startup fence. Provider/history-UI work continues
   independently. Undo/history controls load their required exact evidence on
   demand; missing evidence disables that operation, not unrelated typing.

Streaming construction does not publish a partial collection: all rows/context,
search initialization and final generation checks still precede editable publication.
The optimized clean-exit benchmark begins with fully current rows and a successfully
checkpointed/closed database. Failed materialization/checkpoint maintenance retains
the existing durability and recovery policy; fast-path measurements do not turn
maintenance failure into permission to discard committed work or block a durable quit.

The existing `START-01` choice for positively disclosed newer/required provider
bytes absent locally still applies. The local startup fence neither waits for
unknown cloud history nor bypasses a previously established provider-withheld
startup gate. A malformed derived row requires materialization reconstruction;
a SQLite I/O or integrity failure affecting shared/required database structure is classified
as store damage. Neither permits resetting required private state.

Startup therefore costs current-note decoding plus indexed newly applicable/
unmaterialized work. It need not be O(1), and a large
unprocessed backlog can still take time. It has **no mandatory O(total historical
bytes/actions) pass**. A provider catalog may be enumerated asynchronously;
only unknown candidate objects are read, and exact identity lookups deduplicate
known objects. FSEvents and upload status remain scheduling hints, not coverage.

Do not run full `integrity_check`, rehash every old BLOB, or recursively re-prove
the entire retained pin at every healthy launch. Prior successful acceptance is
reused under private-store continuity. On-demand reads validate exact bytes and
dependencies; positively discovered loss/corruption enters the existing repair
policy immediately. Valid current rows do not excuse **known** history loss. Rebuilding an
invalid materialization, fresh bootstrap, or repairing known damage may require
full history work and is explicitly outside the healthy fast path.

## Validation and remaining implementation work

The focused executable and bounded-model results are recorded in
[fast-start validation](plan/sqlite-fast-start-validation.md). Together with the
prior real transaction/crash probes they test the mapping, not finished Swift
code. Production still requires complete canonical authoring-context/index
codecs, SQLCipher/VFS qualification, and implementation/fault qualification of the
key and backup/salvage/activation contracts above. Provider replacement, retained previews, causal undo and
file-generation authorities retain their existing independent release gates.
