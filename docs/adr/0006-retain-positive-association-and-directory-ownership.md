# Retain positive association and directory-object ownership

Status: accepted.

A collection ID identifies history, not the user's selected physical directory. A private local store retains association evidence that must be independently validated; neither identical bookmark bytes nor a pathname authorizes attachment or deletion. Store/root/profile/key mismatch preserves evidence and requires explicit recovery.

Use nonblocking exclusive flock on the already-open validated root directory and private-store directory, each with one retained owner. No provider-visible lock child, per-session WAL lock or fallback resource is equivalent. Contention/unsupported acquisition admits no writer to that resource. Same-object moves and controller/authority handoff transfer ownership without unlock/reopen gaps; cancellation/scan descriptors never close the owner. Release follows owned operation and observer teardown.

A returning offline store may recover/edit under its exclusive private ownership while the provider root is unavailable, but must acquire/validate root ownership before provider access resumes. Known live root contention is not bypassed. A replacement at the old pathname is independently lockable and remains fenced as another object. These locks exclude cooperating local writers, not remote Macs or arbitrary editors.

Fresh deep-HFS+ opening has an explicit compatibility limit where supported Foundation APIs cannot produce the positively bound root reference needed for coordination. Preserve the safe unavailable result, repository contents and healthy private editing; qualify ordinary HFS+ opening and already-owned deep moves separately. A later Retry, explicit relocation/reassociation or Save Current Collection As… uses the existing root/recovery rules. This capability failure alone supplies neither Work Offline eligibility nor authority over a replacement. The tested refusal is distinct from a successful fresh open and preserves all identity, ownership and durability checks.

AV-16 validates the tested directory primitives; private-store integration, dataless/provider roots and teardown remain explicit implementation gates. No lock supplies absent identity evidence.

The private association carries platform-discriminated passive bookmark data and
local physical hints. Resolution is followed by independently acquired ownership
and physical comparison. A bookmark may resolve an ambiguous replaced pathname;
that result cannot transfer authority. Explicit Re-open uses the same collection's
complete private history, commits its association, and reads that record back
after an ambiguous completion. Keep one unsettled transition owning both resources;
stop/join entered old work before releasing its original root. A committed binding
survives cancellation or a lost callback. See the
[P5.5 contract and evidence](../impl-proposal-5/plan/phase5/05-startup-and-root-reassociation-validation.md).

Normative requirements: AUTH-01, START-01, ROOT-01.
