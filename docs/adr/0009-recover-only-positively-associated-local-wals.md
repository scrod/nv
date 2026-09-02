# Recover only positively associated local WALs

Status: accepted.

Startup scans the exact host-local Recovery Journals directory and validates every modern WAL header before resolving its root bookmark. A WAL becomes mandatory recovery evidence only when the resolved bookmark and independent rooted-directory identity positively associate it with the selected root. Every matching WAL must be recovered, proven already represented, or deliberately preserved before editing begins. Unrelated, unavailable, malformed, copied, and ambiguously associated files remain untouched and grant no cleanup authority.

When several WALs positively match one root, NV snapshots and recovers all of them. It preserves LSN order within each WAL, assumes no order across WALs, and preserves differing nondeletion states using the specification's deterministic automatic conflict-preservation identity. Base-mismatched ordinary deletions and settings never overwrite, delete, or restore. A reserved version-8 `DeletedNoteObject` contributes only its additive retirement identity under base mismatch and grants no deletion authority. One exactly verified checkpoint must represent every recovered result, including every asserted retirement, before any of those WALs are removed and a fresh WAL becomes append-capable.

The only root-local journal input is the legacy exact-name epoch-4 WAL. Modern WALs never enter a provider namespace, so no provider `NSFileVersion`, remote-writer claim, domain enumeration, active/retained registry, or provider upload status participates in recovery. Uncertain local evidence blocks fresh WAL creation until Retry, a verified **Save Current Collection As…**, or explicit abandonment resolves the startup choice.

Normative requirements: `START-01`, `DUR-01`, `CLEAN-01`, `ROOT-01`.
