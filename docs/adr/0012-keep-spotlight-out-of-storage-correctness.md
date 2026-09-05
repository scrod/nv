# Keep Spotlight out of storage correctness

Status: accepted.

Required startup, history discovery, plaintext reconciliation, conflict disposition, dirty clearing and close do not construct or wait for NSMetadataQuery. Disabled/excluded/rebuilding Spotlight cannot suspend storage correctness. Metadata search is not an exact provider snapshot or global inventory.

Immutable-history discovery incrementally inspects the reserved protocol namespace, validates exact objects and unions accepted evidence. Plaintext reconciliation independently uses equal complete coordinated shallow note catalogs around selected current reads. NV Data, legacy databases/journals, directories and owned residue are excluded from ordinary note import. Nested protocol changes require scoped discovery; no root-presenter notification is presumed complete.

Apple unresolved-version queries are per-visible-file explicit-disposition input, never routine history completeness. A later optional metadata query may supply advisory progress/wakeups only; its absence/delay/wrong results change no permission or UI availability. Encrypted note/history content is not exported to Spotlight/Quick Look.

Normative requirements: DISC-01, START-01, PUB-01, REC-01, CRYPT-01.
