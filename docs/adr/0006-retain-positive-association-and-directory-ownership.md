# Retain positive association and directory-object ownership

Status: accepted.

A collection ID identifies history, not the user's selected physical directory. A private local store retains association evidence that must be independently validated; neither identical bookmark bytes nor a pathname authorizes attachment or deletion. Store/root/profile/key mismatch preserves evidence and requires explicit recovery.

Use nonblocking exclusive flock on the already-open validated root directory and private-store directory, each with one retained owner. No provider-visible lock child, per-session WAL lock or fallback resource is equivalent. Contention/unsupported acquisition admits no writer to that resource. Same-object moves and controller/authority handoff transfer ownership without unlock/reopen gaps; cancellation/scan descriptors never close the owner. Release follows owned operation and observer teardown.

A returning offline store may recover/edit under its exclusive private ownership while the provider root is unavailable, but must acquire/validate root ownership before provider access resumes. Known live root contention is not bypassed. A replacement at the old pathname is independently lockable and remains fenced as another object. These locks exclude cooperating local writers, not remote Macs or arbitrary editors.

AV-16 validates the tested directory primitives; private-store integration, dataless/provider roots and teardown remain explicit implementation gates. No lock supplies absent identity evidence.

Normative requirements: AUTH-01, START-01, ROOT-01.
