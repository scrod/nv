# Publish exact copies of durable local segments

Status: accepted.

Every final segment is first installed durably in Application Support; the identical sealed bytes are published into visible NV Data under a random writer epoch and sequence/hash name. These are write-once files, not provider-visible mutable WALs. Distinct hashes preserve same-sequence forks; epochs restart after process/backup restoration. Exclusive installation and exact verification replace shared mutable refs.

Local durability, installation at the local provider namespace, provider-reported upload and another NV's durable receipt are separate facts. None waits for remote acknowledgment before admitting an edit or logical delete. Receivers may store a child before parents, but only validate/apply complete local closure. No remote receipt, membership registry, upload-qualified cleanup or provider version ledger exists.

Retain all accepted/sealed local and provider history/descriptors in v1, including clean-quit unpublished work. Current rows and provider snapshots do not authorize history pruning. A missing provider copy may be republished from exact local bytes after rooted authority validation; it is not logical deletion or proof of attack. Backup exclusion appropriate for a transient WAL is inappropriate for this store's only unpublished data.

Routine transport selects bounded exact accepted objects at a private history prefix,
releasing database work before filesystem effects. Discovery preserves nested parent
progress and revisits directories through ordinary opportunities after an empty pass.
Rebuildable accepted-file hints reuse fresh unchanged-file observations across reopen;
live root/session checks and exact accepted membership remain separate requirements.
Bounded held-directory metadata and indexed accepted-hint groups amortize these
checks. Across turns, raw buffered names are freshly observed; EOF preserves the
unconsumed tail. The lookup binds ordered inputs and the live store incarnation,
while each object's durable receive remains independent. Store/integrity errors
retain their existing outcomes. [Batch qualification](../impl-proposal-5/plan/phase5/bounded-discovery-batches-validation.md)
records exact-field, parser, context, partial-failure and work-count evidence.
The [P5.3 contract](../impl-proposal-5/plan/phase5/03-local-repository-exchange.md)
and [discovery model](../tla/RepositoryDiscoverySafety.tla) qualify this connection.

The [P5.4 adapter](../impl-proposal-5/plan/phase5/04-apple-coordination-and-discovery.md)
places native effects inside actual Foundation grants. A uniquely owned stage
descriptor connects preparation to final exact verification/exclusive rename;
metadata-only provider changes preserve that binding. The session's bounded
driver keeps incomplete publication bytes and resumes after owner settlement or
an ordinary revisit. Cancellation retains entered resources through return.
These execution resources add no persistent transport records.

Normative requirements: DUR-01, DISC-01, CLEAN-01, BACKUP-01.
