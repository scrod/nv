# Seal complete action groups into write-once segments

Status: accepted.

New storage compression uses zstd, with uncompressed encoding still permitted.
Each provider envelope uses an independent dictionary-free frame; private-row
dictionaries are local metadata, never prerequisites for decoding a received
segment. The [compression profile](../impl-proposal-5/Encryption.md#compression-profile)
fixes framing and limits. Zlib remains confined to epoch-4 database/WAL compatibility.

One local sealer per collection captures existing pending generations into bounded immutable segments. This replaces a second mutable WAL and WAL-to-segment conversion, not the need for write-ahead durability. Coalesce open saved-edit groups without erasing completed action, birth, delete, retirement or before-state boundaries. One action and all its members fit one envelope; oversized work is explicitly split before admission.

Privately, separate sealing, atomic SQLite acceptance/index/pin/ready commit and exact-generation completion. A committed operation recovers even without its callback; uncommitted SQL writes do not. A stale completion cannot clear newer pending text, and duplicate committed identities create no new batch. Provider publication separately performs staging, file sync, exclusive final-name installation, directory durability and exact verification. Differing bytes under the same identity fail without overwriting.

Writer epochs are fresh on each editable restart/restored backup; an epoch is not an action origin or machine identity. Previously sealed bytes retransmit unchanged. No periodic authoritative database checkpoint, active provider log, shared counter or startup sealing of partial provider files is needed. Provider snapshots and current-row updates do not prune retained history.

Normative requirements: DUR-01, CLEAN-01, HIST-01.
