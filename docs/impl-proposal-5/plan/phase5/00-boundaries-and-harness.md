# P5.0 — Boundaries and production-path harness

Status: root-boundary preparation implemented; see the
[caller inventory](00-caller-inventory.md) and
[P5.1 qualification](01-root-ownership-validation.md). The
[P5.2 file-installation harness](02-immutable-files-validation.md) now observes
actual staged writes, native exclusive rename, file/directory barriers and owned
cleanup, with separate process-cut, permitted-loss and corruption controls.
Dependency: existing Phase 2–4 implementation and evidence.

Follow the [multipart index](../phase5-provider-root-implementation-plan.md) and
[test-boundary rules](../phase5-provider-root-testing-plan.md#3-test-boundary-and-independent-observations).
This part establishes the small set of interfaces and observers used by subsequent
parts; it adds no new storage format or product policy.

## Implementation

1. Inventory actual callers of root ownership, coherent reads, exclusive creation,
   replacement, directory operations, immutable capture, receive, publication,
   repair and copy. For each record intent, issuer/consumer, execution lane,
   captured context, barriers, lifecycle and cleanup ownership.
2. Compare `NVRootedDirectory`, `CStorageIO` and Runtime copy/selection helpers
   against the testing plan's operation table. Mark fresh-destination copy versus
   strict shared-repository installation distinctly. Force weak fallbacks in tests
   before permitting their new use.
3. Define narrow internal effect boundaries: owned root; exact bounded read;
   protocol-scoped enumeration; exclusive immutable install; and preserved
   intent-specific replacement. Identify copied observations versus authority
   and private acceptance versus provider installation. Freeze only signatures
   needed by the next part, with checked constructors and contextual consumers.
4. Select the smallest acyclic Darwin bridge arrangement. Core remains portable;
   Foundation/provider handles stay in the adapter. Co-locate issuers/permission
   types where that prevents public unchecked factories. Retain the current
   strongly checked Runtime and independently owned blocking resource design.
5. Extend existing Swift tests, probe executable, history inspector and Makefile
   selections. Add effect entry/return/held-completion seams at real boundaries,
   independent directory/byte observers and pipe-confirmed process cuts. Reuse
   SQL/VFS and completion controls for the private side.
6. Establish a baseline manifest: revisions, available host/filesystem matrix,
   exact commands/cases, retained fixture locations and unavailable qualification.
   Keep provider/image jobs explicitly selected and respect host permissions.

## State and language boundaries

- Reserve an operation's immutable input and session context before suspension;
  its final consumer rechecks applicability.
- Keep owned descriptors/handles inside their owner. Cross-boundary data consists
  of copied bytes, validated locators and closed observations/outcomes.
- Identify unavoidable C/Objective-C assumptions with strict memory diagnostics
  and narrow audited lifetime wrappers. TestSupport remains a test dependency.
- Defer any persistent discovery/publication bookkeeping until its crash need is
  demonstrated. Existing accepted membership, queue and private groups remain
  the durable source; test observation logs are not recovery inputs.

## Tests and exit gate

Build/run the current valid local-save/reopen companion through the new harness
without changing results. A deliberately lying effect result must fail the
independent observer. A cut not reached must be reported as an invalid witness.
Self-test planned persistence-loss rules against omitted barriers and an
always-durable model defect; record permitted per-primitive loss/atomicity rules.

Add ordinary-client and same-module construction probes for boundaries introduced
now, plus matching-context positive clients. Verify fixture/test discovery and
retained artifact reporting. Initial harness checks do not certify an unimplemented
provider issuer.

Exit when the inventory identifies reuse and capability gaps, the harness observes
real effects independently, and the boundary/ownership design is sufficient to
start P5.1 without exposing an unchecked receipt or weakening a contract. Record
the selected target/bridge arrangement in the implementation contract.
