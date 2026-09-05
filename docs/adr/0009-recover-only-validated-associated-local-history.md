# Recover only validated, positively associated local history

Status: accepted.

Recovery opens an exclusively owned private store, validates its selected collection/profile/key and physical association, then validates final objects and reconstructs dependency-closed history. Include installed objects even if their callback/publication hint was lost. Stale/missing cache never suppresses retained tail operations or replaces private state; partial staging, corrupt envelopes and incomplete closure are not editable success.

Foreign/copy-ambiguous stores remain preserved and unattached until explicit selection/association. A restored local backup uses a new writer epoch and revalidates physical observations; it cannot replay old delete permission. A matching logical collection ID may enable deliberate history import, never silent root retargeting.

Legacy archive/WAL decoding remains on the legacy migration path, preserving valid-prefix and positively associated recovery safeguards. Do not require creating an unpublished proposal-4 WAL/header format for a new segment store, or infer cross-WAL order, a service acknowledgment, or cleanup permission from legacy metadata. Migration verifies a complete independent destination before any source cleanup.

Normative requirements: AUTH-01, START-01, DUR-01, CLEAN-01.
