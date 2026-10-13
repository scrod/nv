# Use immutable history as recovery and synchronization authority

Status: accepted.

Committed NV operations and their explicit parents, not a mutable database checkpoint or provider version store, define reconstructible note history. Validate complete envelopes and locally persist their dependencies before application. Union accepted operations monotonically; duplicate receipt has one logical effect, omitted provider objects retract nothing, and counters/timestamps do not prove coverage.

Repository transport installs complete sealed stages through a qualified native exclusive rename, verifies exact final bytes and obtains file/nested-directory barriers. Equal-file retries repeat verification and barriers; incompatible occupants survive. Physical installation evidence and private history acceptance have separate restricted issuers and contextual consumers. Their connection is the publication caller's responsibility. Unsupported filesystem capabilities leave local saving intact. See [P5.2's contract and evidence](../impl-proposal-5/plan/phase5/02-immutable-files-validation.md).

Private SQLite current rows are derived materialization, not a packed startup cache. Optional provider snapshot roots/pages accelerate their exact stated frontier without becoming canonical or permitting history deletion. Required Local State rows independently own private settings, root association and the retained-history pin; remote operations do not merge preferences. Action-origin provenance lives in retained action records, as specified by [ADR 0015](0015-retain-history-and-use-compensating-undo.md), not in a private undo continuation. A copied collection ID cannot establish physical-root authority.

Segment collections have no shared Notes & Settings CAS or NVCheckpointInstallCurrentChanged note merge at quit. Apple's unresolved plaintext versions are separate explicit inputs; neither those APIs nor current-file availability limit NV's own retained history. Epoch-4 archives remain legacy/open/export artifacts, never a second live authority for the same segment collection.

Normative requirements: START-01, DISC-01, PUB-01, CKPT-01, HIST-01.
