# Keep Spotlight out of storage correctness

Status: accepted.

NV will not use `NSMetadataQuery` or Spotlight to gate startup, reconciliation, rebuild, dirty clearing, or any completeness claim. Apple documents `NSMetadataQuery` as metadata search, but does not give it a bounded completion time or a complete, exact File Provider snapshot contract; disabled, excluded, rebuilding, or damaged Spotlight state therefore cannot be allowed to suspend NV's storage lifecycle.

The authoritative discovery path is a coordinated shallow `NVRootedDirectoryCatalog` projected into current direct-child note files and fixed NV artifacts. The note candidate set combines that current catalog with live-model and last-accepted identities and note URLs supplied by presenter move callbacks. It excludes `Notes & Settings`, the legacy exact-name WAL, hidden `.nv-write-<UUID>` residue, and directories; the directory-descriptor lock creates no artifact, and modern WALs cannot appear because they live in Application Support. Only selected current files require materialization. Two equal complete catalogs surrounding those reads form the current-visible fence. Failure, incompleteness, or a changed fence preserves the dirty obligation and publishes no destructive result.

`NSFileVersion` history is not part of routine discovery. A nonempty unresolved-version query for one currently visible note may show the explicit conflict-resolver badge, but it proves neither a complete history nor routine reconciliation completeness. The initial implementation omits `NSMetadataQuery` entirely. A later implementation may use it only for advisory progress or wakeups whose absence, delay, or incorrect results cannot alter startup, publication, recovery, conflict disposition, cleanup, or UI availability.

Normative requirements: `START-01`, `DISC-01`, `PUB-01`, `REC-01`.
