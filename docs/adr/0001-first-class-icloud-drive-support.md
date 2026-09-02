# Give iCloud Drive first-class support

Status: accepted.

NV provides tested first-class iCloud Drive support when the selected root uses unencrypted `PlainTextFormat` separate-file storage. Entering that contract requires a complete plain-text export and the existing formatting-loss disclosure. The live in-memory store remains authoritative while NV runs; separate note files are the routine cross-Mac representation, and `Notes & Settings` remains the complete fast-start checkpoint and sole database source of settings and metadata. Modern WALs are private host-local Application Support artifacts and never a synchronization representation.

Runtime correctness does not depend on identifying a provider vendor. Current positive ubiquitous-item or forward File Provider evidence establishes provider management; absence, failure, or ambiguity leaves authority unclassified and grants no ordinary-local inference. iCloud Drive is validated as a ship target. Dropbox and other providers receive compatible best-effort behavior under the same plaintext contract. NV stores no provider-brand mode or persistent capability profile, and advertised capabilities authorize only the corresponding attempted operation.

Routine synchronization is current-visible and uses coordinated catalogs and current note files. Apple-reported unresolved versions for a visible note are available only through explicit embedded conflict disposition. NV does not use provider history to claim completeness, automatically recover or resolve it, qualify local WAL cleanup, or establish cloud durability. Provider upload status is presentation state. Encrypted, database-only, RTF, HTML, and hypothetical third-party compatibility formats remain outside the first-class provider-managed contract.

Normative requirements: `AUTH-01`, `START-01`, `DISC-01`, `PUB-01`.
