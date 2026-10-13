# P5.1 — Root ownership and independent execution

Status: complete within the recorded platform qualification boundaries. The
descriptor-owned root, scoped metadata observations, independent execution and
cancellation/quiesce/close lifecycle have production witnesses; see the
[qualification and later gates](01-root-ownership-validation.md).
Dependency: [P5.0](00-boundaries-and-harness.md).

Testing: [P5-ROOT and lane/lifecycle rules](../phase5-provider-root-testing-plan.md#roots-coordination-and-lifecycle),
TC-ROOT-01, TC-LIVE-01 and AV-15–16. This part qualifies local ownership/execution;
P5.4 later supplies the actually entered Apple-accessor witness.

## Implementation

1. Introduce one repository/root owner around a non-followed directory descriptor,
   nonblocking exclusive directory-object lock and session/lifecycle generation.
   Reuse qualified C/rooted primitives and the Runtime executor lifetime pattern;
   independently validate each new resource/caller rather than borrowing a path.
2. Keep private-store ownership with the existing local owner. Establish root
   ownership before repository access/mutation and preserve an acquired owner
   continuously through handoff. Contention and unsupported acquisition are
   distinct outcomes; no child lock file or fallback exclusion resource.
3. Implement descriptor-relative observations and effect permission tied to this
   root session. Explicit selection identifies a candidate resource; collection
   IDs/bookmarks alone cannot attach it or authorize writes.
4. Own a separate bounded blocking execution resource for repository effects.
   Reserve immutable work before suspension and keep handles/buffers until its
   actual completion/fencing. Local database work uses its existing separate lane.
5. Define small closed lifecycle states and explicit invalidation events. Positive
   same-object moves retain the owner; unknown/different continuity fences affected
   work. No old-path reopen transfers ownership to a replacement.
6. Implement quiesce/cancel/teardown around owned operations and observers. Scans
   close their own descriptors. Borrowed/duplicated handles do not unlock or
   prematurely close the owner. Cleanup is completion-driven, not a fallible
   persistence promise in `deinit`.

## State and language boundaries

Keep only session-local root identity/context, lifecycle, owned in-flight work and
generation counters needed for fencing. Use actor isolation for mutable control
state when it simplifies the complete design; synchronous filesystem turns stay
on the dedicated blocking resource. Recheck after `await`. A typed handle carries
lifetime/context, while the effect runner establishes current physical authority.
Selective noncopyability is useful only where it makes resource plumbing clearer.

Use restricted construction for root/effect permission; keep raw handles and
platform URL objects inside the adapter. Preserve v2's ordinary-client and
same-module checks and audited C disposal instead of broad unchecked Sendable.

## Tests

- Independently exec contenders against one physical directory; repeat after child
  creation, scan close, same-object move, descriptor handoff and final close.
- Kill a pipe-confirmed holder and reacquire. Recreate its old path while the moved
  original remains held; the replacement is independently lockable but cannot
  receive the old session's effects, even with identical collection bytes.
- Exercise symlinks/wrong kinds, unavailable volumes, permission failure, unknown
  continuity, stale-session permission and separate private-root contention.
- Hold a real blocking effect on the repository execution resource while a local
  save/barrier and fresh local reopen succeed. This is an execution witness,
  distinct from P5.4's coordinated provider witness.
- Cancel/quiesce during an owned effect, attempt another operation, then release.
  Check reentrancy, late completion, exact cleanup count and descriptor baseline.
- Mutate path equality as authority, shared lanes, owner release from scan/cancel
  and omitted post-suspension checks. Require positive companions and intended
  independent failures.

Run available native directory/filesystem and Linux qualified-ownership checks
with exact OS/architecture context. Keep cold dataless-directory behavior and
remote-origin events unqualified until actual stimuli are observed in P5.4/P5.7.

## Exit gate

The production owner excludes cooperating local contenders, preserves continuous
ownership and never retargets by path/ID. Local durability progresses independently
of held repository work. Compiler and dynamic lifetime/context challenges pass;
unknown or unqualified root access reports a conservative explicit outcome.
