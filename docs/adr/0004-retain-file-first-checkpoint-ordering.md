# Retain file-first quit ordering

NV will freeze editing, complete a final provider/reconciliation barrier, and settle both WAL durability and affected separate-file writes before serializing and installing the termination database checkpoint. Installation succeeds only after a coordinated read-back exactly matches the serialized bytes, decodes, and contains the expected checkpoint identity. NV removes the WAL after local durability for a confirmed ordinary local directory, or after exact-checkpoint upload confirmation for iCloud. Any failure before checkpoint installation follows one retry-or-quit-anyway path that preserves the old checkpoint, WAL, and active-journal record.

This establishes local crash consistency and avoids serializing a second set of pending export obligations, but it does not promise iCloud cross-file delivery order: separate files remain the routine note-sync representation and any divergent database version remains recovery evidence.
