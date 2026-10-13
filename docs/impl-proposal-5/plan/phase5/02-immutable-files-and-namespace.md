# P5.2 — Immutable files and rooted namespace operations

Status: implemented and qualified within the documented filesystem/platform
limits. See [production witnesses and results](02-immutable-files-validation.md).
Dependency: [P5.1](01-root-ownership-and-execution.md).

Testing: [physical-operation contracts](../phase5-provider-root-testing-plan.md#4-qualify-physical-operations-by-intent),
[failure sweep](../phase5-provider-root-testing-plan.md#5-failure-and-crash-exploration),
TC-DUR-05, P5-CLEAN, P5-PRIV and AV-17.

## Implementation

1. Implement bounded descriptor-relative entry observation, exact coherent read
   and shallow protocol-directory enumeration under the owned root. Distinguish
   absence, unreadability, kind collision and changed observation. Enforce byte,
   component and encoded-count limits before allocation; enumeration yields at
   its per-turn budget and resumes rather than limiting a collection's file count.
2. Centralize protocol name rendering from validated descriptor/segment locators.
   Reject traversal, reserved/invalid leaves, symlinked intermediate directories,
   wrong kinds and contradictory locator/collection/profile inputs. Discovery of
   renamed valid duplicates will use envelope identity, not blind filename trust.
3. Implement complete-stage exclusive immutable installation: create owned stage,
   write/verify/synchronize, install without overwrite, reopen exact bytes/identity
   and obtain required affected-directory barriers. Qualify the actual mechanism
   on each claimed filesystem; a direct visible-final copy cannot satisfy it.
4. Equal preexisting finals go through exact verification and required durability
   work. Preserve mismatching, foreign or wrong-kind occupants. Distinguish no
   effect, verified installation and ambiguous/reclassification outcomes; preserve
   exact retry input when completion/barriers are uncertain.
5. Create protocol directories add-only under fresh positive observations. Recheck
   each competing entry, preserve winners and synchronize the appropriate nested
   namespaces. Complete objects may exist in an interrupted partial repository;
   partial repository output is not a completed known-history repair.
6. Implement owned-stage cleanup and failure accounting. Preserve unknown/displaced
   evidence. Keep immutable installation distinct from regular-file replacement
   and populated-directory repair, which receive their consumers in P5.6.

## State and language boundaries

Issue installation evidence only from the effect that established exact bytes,
root context and barriers; bind it to their captured operation/session. Keep it
distinct from private accepted-history receipts. Stage owners retain descriptors
and original inputs through delayed completion. Use nominal immutable locators
versus untrusted discovery names, and closed capability/outcome enums.

Reuse [CStorageIO](../../../../NVStorage/Sources/CStorageIO/NVStorageIO.c) and
[NVRootedDirectory](../../../../NVRootedDirectory.m) selectively. Both existing
copy/absent-file paths require new-use qualification: do not relabel best-effort
results as strict publication. If no qualified primitive exists, report the
capability gap and preserve local saving rather than invent a weaker fallback.

## Tests

- Independent readers observe only complete staged content at final names; force
  each actual installation branch, including the weak visible-final control.
- Same-byte duplicate without prior durability evidence, contradictory bytes,
  concurrent create, descriptor mismatch and root movement/replacement.
- File synchronization versus directory barriers, including new nested writer
  directories and late failure after name installation. Observe actual effects
  separately from error/callback claims.
- Short/zero writes, EINTR where applicable, EIO/ENOSPC/access failures, truncated
  reads and every reachable process cut. Fresh readers use surviving inputs only.
- Leaf/path/size/kind violations, symlink/FIFO/directory/hard-link ambiguity and
  case-sensitive/deep-root companions. Cleanup races preserve foreign evidence
  within the qualified external-producer contract.
- Profile-specific staging/log privacy and exact disposal/lifetime under repeated
  hold/cancel/retry. Add constructor/type/context probes for issued evidence.
- Mutate premature evidence/barrier omission, equal-final shortcut, mutable
  overwrite, partial final visibility and filename-based cleanup; require their
  intended observable failures and successful baseline operations.

Run the applicable image matrix and genuine image ENOSPC/detach/remount, recording
operation capabilities independently from filesystem labels. Keep simulated
persistence loss and later corruption separate from process termination.

## Exit gate

The production read/install boundary meets exact rooted/immutable predicates on
qualified targets. Every failure preserves recoverable inputs and truthful outcomes.
Complete-stage visibility and actual barriers are independently observed; unavailable
capabilities remain explicit. P5.3 can exchange real files without fake receipts.
