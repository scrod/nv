# Use source-preserving key and profile transitions

Status: accepted.

Encrypted segments use the pinned AES-GCM/HKDF envelope and reviewed Argon2id wrapping contract, not legacy CBC/CRC as a new transport format. Authenticate before decompression/interpretation, separate public/private kinds and scopes, generate fresh nonces/writer epochs and retransmit sealed bytes unchanged. Provider metadata remains visible; authentication does not prove freshness, physical authority or safety from a key-holding malicious writer.

Passphrase rewrap adds an immutable descriptor for the same collection key. Old descriptors/secrets may still unlock retained history; the UI must not call this revocation. Full key/encryption-profile changes create a fresh collection/key/genesis in an independent destination. No in-place key succession or old-device fencing is smuggled into v1.

Repository Save As is different: it preserves available exact history/files, collection identity and wrapped-key descriptors, without requiring source private state/unpublished work. It creates no fresh genesis or replacement key. Opening the copy is an explicit fresh local association/origin/writer session; it never resumes a copied writer or retargets by collection ID alone. Current-state-only conversion/export must be labeled separately, not substituted for this copy. Full-history re-encryption is not claimed by the initial conversion path.

Quiesce/capture coherent complete source state, recover legacy evidence first, verify target import/snapshot/required projections and credentials, then commit the active private association. Source files/history/credentials remain usable until success and explicit later cleanup. Keychain and filesystem replacement are independent durability domains: provision fresh items add-only, read back and validate before referencing them; preserve possibly referenced items after ambiguous installation. An independent Save As never updates/deletes the source's item.

Password-free collections have no device-kept secret requirement: the private SQLCipher database uses a documented nonsecret key, so a consistent database copy remains readable without Keychain or a key sidecar. This is not confidentiality. Encrypted private databases derive a domain-separated key from the existing collection key; their recoverable wrapped-key descriptors also live outside the database. Reuse same-CK password rewrapping instead of a second database credential lifecycle or routine native rekey. Provider key/profile conversion remains the separate fresh-destination policy above.

Remember on this Mac applies only to encrypted unlocking and uses explicitly tested signed-app device-bound Keychain access; unavailable/locked is not corrupt and password unlocking remains available. Loss of every encrypted unlocking route can make history unrecoverable. Plaintext migration cannot hide data the provider already saw, and no transition promises secure deletion of provider/APFS/external-editor copies.

Normative requirements: CRYPT-01, START-01, CKPT-01, ROOT-01, BACKUP-01.
