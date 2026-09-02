# Reuse the existing quit flow and status UI

Status: accepted.

NV reuses `SyncSessionController`'s existing uncommitted-change status, waiting, error, cancellation, and explicit quit-override presentation rather than adding a second termination UI. Provider upload state may remain visible there, but it is presentation only and supplies no local durability, conflict-disposition, WAL-cleanup, or cloud-completeness evidence.

Termination first rejects new edits and synchronization admission, lets already admitted model mutations finish, drains presenter callbacks and provider work through one stable final current-visible barrier, synchronizes the host-local WAL, settles affected separate-file writes, and makes the permitted root-closing checkpoint attempt. Exact local installation and verification authorize immediate local WAL removal and Application Support directory synchronization. A provider upload failure, ambiguity, or later user override cannot resurrect or delete a WAL whose local cleanup decision is already durable. A failure or override before local checkpoint verification preserves the WAL for startup recovery. `applicationWillTerminate:` performs no second checkpoint write.

`NVCheckpointInstallCurrentChanged` uses the current checkpoint's exact no-write snapshot for one complete-note-set/base-relative-deletion reconciliation, retired-identity union, exceptional whole-union retirement WAL barrier, and fresh attempt; further contention returns to the same close UI while retaining those assertions for base-mismatch recovery. Root-continuity-unavailable status uses that UI family for Retry, **Save Current Collection As…**, **Re-open from Disk**, or quit, and attempts no checkpoint against the unavailable old root. A local-WAL durability suspension remains a separate edit-admission reason but uses the same recovery choices.

NV implements no pause/upload/resume protocol, exact-upload qualification, legacy upload-transition qualification, retained WAL claim, cleanup receipt, provider-version cleanup, or cleanup-only checkpoint.

Normative requirements: `DUR-01`, `CLEAN-01`, `ROOT-01`, `CKPT-01`, `WAIT-01`.
