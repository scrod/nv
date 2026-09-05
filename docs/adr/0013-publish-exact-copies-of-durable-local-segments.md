# Publish exact copies of durable local segments

Status: accepted.

Every final segment is first installed durably in Application Support; the identical sealed bytes are published into visible NV Data under a random writer epoch and sequence/hash name. These are write-once files, not provider-visible mutable WALs. Distinct hashes preserve same-sequence forks; epochs restart after process/backup restoration. Exclusive installation and exact verification replace shared mutable refs.

Local durability, installation at the local provider namespace, provider-reported upload and another NV's durable receipt are separate facts. None waits for remote acknowledgment before admitting an edit or logical delete. Receivers may store a child before parents, but only validate/apply complete local closure. No remote receipt, membership registry, upload-qualified cleanup or provider version ledger exists.

Retain all accepted/sealed local and provider history/descriptors in v1, including clean-quit unpublished work. Current rows and provider snapshots do not authorize history pruning. A missing provider copy may be republished from exact local bytes after rooted authority validation; it is not logical deletion or proof of attack. Backup exclusion appropriate for a transient WAL is inappropriate for this store's only unpublished data.

Normative requirements: DUR-01, DISC-01, CLEAN-01, BACKUP-01.
