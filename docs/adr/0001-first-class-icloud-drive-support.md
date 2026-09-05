# Give iCloud Drive provider-agnostic segment support

Status: accepted.

NV supports ordinary user-selected provider folders through two explicit immutable collection profiles: PlaintextFilesV1 keeps interoperable plaintext notes alongside visible NV Data; EncryptedSegmentsV1 transports encrypted history without plaintext files in that folder. Separate-file support remains a product feature, not a requirement to expose encrypted notes. Existing rich content must survive an encrypted migration or receive explicit unsupported/conversion handling.

The live in-memory store and synchronous search remain authoritative during use. Immutable NV history carries committed values/identities/deletion intent; exact durable local copies and later provider copies have different roles. No shared Notes & Settings, dedicated iCloud container, CloudKit service, custom provider extension or provider-brand mode is required. iCloud is the first-class tested target; other providers get the same conservative behavior within established contracts.

Positive provider evidence can authorize an attempted operation, never a global synchronization claim. Unknown classification does not prove ordinary-local storage. Encryption protects payloads from a provider without the key, not availability, undisclosed branches, authorized malicious writers or a compromised unlocked Mac.

Normative requirements: AUTH-01, START-01, DUR-01, CRYPT-01, BACKUP-01.
