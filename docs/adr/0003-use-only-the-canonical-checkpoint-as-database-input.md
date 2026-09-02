# Use only the canonical checkpoint as database input

Status: accepted.

Separate note files, not divergent `Notes & Settings` versions, perform routine cross-Mac note convergence. The accepted canonical checkpoint is the only startup database and the sole database source of settings and metadata. NV does not enumerate, decode, recover, resolve, remove, or expose noncanonical or historical checkpoint versions. There is no **Recover Notes**, historical checkpoint picker, automatic database-version recovery, or **Discard** action.

The only additional database input is the exact canonical current checkpoint returned without mutation when a root-closing expected-current compare-and-swap reports `NVCheckpointInstallCurrentChanged`. NV compares its complete note set with the exact retained accepted checkpoint and complete live note set, treating absence as deletion only for a UUID present in that exact base, and unions the compact retired deterministic conflict identity set before allocating conflict identities. It leaves live preferences and other database-scoped metadata unchanged. On this exceptional path it reasserts the complete retired union as version-8 records in the host-local WAL, settles those plus new note/removal and separate-file obligations, and retries against that exact current checkpoint. Unreadable bytes or another current change perform no overwrite and return to the close workflow; base-mismatch recovery unions the durable retirement assertions without applying deletion.

Apple-reported unresolved versions of currently visible separate note files remain a distinct explicit conflict-disposition input. They never make a checkpoint version eligible for recovery and never alter database settings.

Normative requirements: `START-01`, `REC-01`, `CKPT-01`.
