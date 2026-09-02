# Keep the database name and epoch-4 checkpoint compatibility

Status: accepted.

Modern NV keeps the canonical `Notes & Settings` filename and an epoch-4-readable core archive. `FrozenNotation.checkpointID` is an optional 16-byte field that epoch 4 ignores. A fresh modern checkpoint receives a random identity with equality semantics only. Until exact unchanged epoch-4 bytes receive such an identity on a verified modern save, a host-local WAL identifies its base with tag `0x02` plus SHA-256 of those exact bytes; modern identified checkpoints use tag `0x01` plus the 16 UUID bytes.

Modern NV recovers the legacy exact-name root WAL before creating a fresh host-local WAL. Epoch 4 can read a clean modern checkpoint but cannot recover a modern Application Support WAL, so a modern crash must be reopened with modern NV. NV maintains no hard-link, clone, or copied legacy WAL alias. New WALs use only the version-2 host-local layout, and no compatibility is required for unpublished epoch-5 journal, claim, ancestry, receipt, or provider-version-representation formats.

Normative requirements: `START-01`, `DUR-01`.
