# Retain file-first root-closing ordering

Status: accepted.

NV will freeze editing, complete a final current-visible reconciliation barrier, and settle both host-local WAL durability and affected separate-file writes before serializing and installing a root-closing database checkpoint. Quit and ordinary folder switching use the same closure path while positive root continuity permits the old root to accept it. If continuity becomes unavailable, NV attempts no old-root checkpoint: Retry may restore it from positive same-root evidence, **Re-open from Disk** preserves the unavailable local WAL, and **Save Current Collection As…** constructs an independent collection whose verified checkpoint may cover and retire that WAL.

Every checkpoint transaction enforces one root-session-scoped expected-current witness immediately before replacement: complete bytes, the existing `NVFileObservation`, and the available local `NSFileVersion` identity as supplemental evidence; creation and rebuild require expected absence. A mismatch or unexpected appearance performs no namespace mutation. Rebuild restarts discovery. Root closure may use the exact no-write `NVCheckpointInstallCurrentChanged` witness for one automatic complete-note-set/base-relative-deletion reconciliation, retired-identity union, whole-union local-WAL retirement barrier, and fresh attempt, but it never imports the competing checkpoint's preferences or other database metadata. An unreadable snapshot or second observable change returns to Retry, **Save Current Collection As…**, or the existing explicit override without discarding those local retirement assertions.

After exact local checkpoint installation, directory durability, read-back equality, successful decode, and checkpoint-identity verification, NV closes and removes the covered host-local WAL and synchronizes the Application Support recovery directory. Provider upload status cannot authorize, delay, or reverse that cleanup. A pre-verification failure or ambiguous possible installation preserves the WAL. A provably header-only WAL may be removed after directory durability, and closure skips checkpoint installation when no checkpoint-scoped state changed; uncertain bytes forbid either shortcut.

`CurrentCheckpointNoteMergeSafety` checks the no-write mismatch/retry boundary, and `LocalWALSafety` checks exact local coverage and WAL deletion ordering. Neither model assumes provider upload or cross-file cloud transactionality.

Normative requirements: `DUR-01`, `CLEAN-01`, `ROOT-01`, `CKPT-01`, `WAIT-01`.
