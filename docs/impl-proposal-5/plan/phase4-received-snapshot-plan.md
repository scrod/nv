# Phase 4 S2: received snapshots, exact waits and restart recovery

Date: 2026-10-03. Status: implemented; qualification results and platform limits
are recorded in the [S2 report](phase4-received-snapshot-validation.md).
This increment follows [durable local snapshot acceptance (S1)](phase4-snapshot-acceptance-validation.md).
It makes S2 of the [acceptance/recovery plan](phase4-snapshot-acceptance-recovery-plan.md)
concrete. Complete each gate below before expanding it.

## Goal and scope

Receive exact snapshot root/page envelopes in either order, retain them privately,
wait for precisely the bytes and accepted history they need, then accept a complete
verified general snapshot through S1's transaction. Crashes, duplicate delivery
and finite local-save interference must preserve the inputs and eventual progress.

Start with an already complete, owned collection bootstrap. Initial/general payload
dispatch must preserve their distinct formats; retained initial inputs route to
the complete-bootstrap consumer, whose store-backed/large-import expansion remains
S3. The positive S2 acceptance gate uses general snapshots and already accepted
bootstrap evidence. S2 adds no permission to open an incomplete new collection.

Snapshot acceptance retains evidence; ordinary history reduction continues to
supply Current. Installing snapshot values as rebuilt current rows remains S4.
Provider discovery/publication, UI, backup/salvage/activation, compression changes
and garbage collection retain their separate gates. Both profiles use encrypted
private SQLCipher pages and the existing keys, zstd and canonical wire layouts.

Authority: [specification](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state),
[Protocol](../Protocol.md#snapshots-startup-rejoin-and-retention),
[LocalStore](../LocalStore.md#logical-schema-and-transaction-boundaries),
[CONTEXT](../../../CONTEXT.md), ADRs
[0005](../../adr/0005-separate-startup-cache-private-state-and-visible-history.md)
and [0016](../../adr/0016-repair-from-validated-immutable-copies.md).
Use the [Swift design](swift-storage-library-proposal-v2.md),
[conformance strategy](swift-storage-conformance-testing-strategy.md) and
[Phase 4 safety contracts](phase4-data-safety-contracts.md), especially T01–T05/T10,
`TC-START-01`, `TC-DUR-01/04/06`, `TC-EVD-01`, `TC-LIVE-01` and `TC-LIMIT-02`.

## Preserve the distinctions that prevent loss

| Concern identified during Phase 4 work | S2 mitigation and observation | Later gate still required |
| --- | --- | --- |
| A snapshot's operation cut differs from the objects retained to verify it | Retain full Changes membership, including another complete group in the same envelope and an earlier accepted divergent branch. Acceptance updates the current pin, preserves Current and authors no action. | S4 must rebuild from the cut plus every accepted operation outside it; acceptance/reopen alone cannot qualify rebuilding. |
| Surviving SQL indexes could omit an action still present in accepted bytes | Reuse the accepted-envelope membership audit. Deliberately remove an isolated operation/action index entry; verification diagnoses required-history damage rather than certifying an incomplete snapshot. | S4/repair must also refuse editable reconstruction past known required loss. |
| Equal visible bodies can conceal different conflicts, deletion or Undo/Redo state | Reuse complete semantic claim comparison and run body-equal/different-reference fixtures, with genuinely nonempty scope frontiers and retained copy/retirement/Restore/compensation records. | S4 must preserve those relationships through actual row installation and subsequent queries. |
| Equal store IDs/counters and delayed completions can outlive physical ownership | Consume connection/session-bound evidence, preserve same-ID copied-store negatives, and close/reopen/save before releasing an old completion. Snapshot results remain separate from saved-note receipts. | The S4 installer adds target/view/presentation/live-generation fences. |
| Page arrival and history acceptance unblock different work | Distinguish retained assembly bytes from accepted history; wake on both transitions and atomically recheck requirements when parking. | S3 must establish the complete original import commitment on a fresh store. |
| Bounded pages can still produce large total work, RAM use and abandoned candidates | Measure total decoded state, history reads and writer turns; yield preparatory work, preserve exact retry inputs and explicitly report disk failures. Duplicate intake adds no second byte copy. | S3/S4 qualify large bootstrap/rebuild; cleanup is a separately owned operation and does not prune accepted/sealed history. |

## Implementation order

### R1 — Typed intake and durable assembly inputs

1. Factor the existing envelope/kind/version dispatch for Changes, initial/general
   pages and roots. Selected collection/protection, exact identity and outer bounds
   precede admission. A pre-admission failure reports no retained or accepted
   result; the caller/source remains responsible for its input.
2. After compatible outer validation, retain exact bytes and metadata. Intrinsically
   unsupported or invalid payloads use the existing preserved-candidate rejection
   path. Structural checks belonging to a root, such as complete ranges, stream
   counts and digest, remain root assembly checks. All validators interpret the
   same owned bytes that passed envelope checking.
3. Reuse `objects`, `ready_objects`, `object_waits` and `rejected_objects`. Introduce
   no per-page accepted flag, persistent traversal cursor, secondary queue, sidecar
   or long-lived validation cache. Reparse retained page inputs at their consumers.
4. Extend the closed receive outcomes with a retained-for-assembly page result.
   An unaccepted valid page can be retained without runnable standalone acceptance
   work. Roots/Changes requiring validation remain ready or waiting; tests must
   distinguish these roles rather than require every inert page to be ready.
5. Use a small requirement enum distinguishing **retained assembly bytes** and
   **accepted history**, each carrying an exact `SegmentLocator`. Use it in
   preparation/parking and waiting diagnostics; freeze its spelling and public
   outcome changes with the first implementation. Persist only existing exact-ID
   waits: retained immutable root/page bytes reconstruct the expected locators
   and roles after restart. A status query reruns bounded discovery, never takes
   an object ID alone as proof of matching bytes or acceptance.

Prepare owned, checked `Sendable` intake values off the database writer. Reserve
the existing receiver before suspension; the synchronous retention consumer
rechecks the actual owner/header and exact existing bytes. Construction and
receiving share candidate-retention helpers wherever their obligations match.
Keep ordinary clients unable to construct acceptance evidence or consume a page
result as a durable saved-note receipt.

**R1 gate:** both profiles retain/reopen exact pages and roots through the public
intake/status APIs. A standalone valid page remains unaccepted; a matched complete
general root succeeds via S1. Unsupported/invalid companions preserve the selected
failure classification and accepted history. Existing Changes behavior still passes.

### R2 — Arrival wakeups and atomic parking

Keep the existing acceptance trigger. Add an explicit, shared arrival-wakeup helper
inside candidate retention; no new table or trigger is needed for the baseline.
Use indexed reverse waits and enqueue only retained, unaccepted, unrejected children.
Apply the helper to received inputs, local snapshot emission and exact duplicate
redelivery, so the source of usable bytes does not determine progress.

The retention transaction commits the exact input and all applicable ready wakeups
together. An extra wake can make a Changes child recheck and repark because its
parent is only retained. It cannot bypass the accepted-history predicate.

For root assembly:

1. Read retained exact pages through the existing complete preview reader. Missing
   pages yield retained-byte requirements. As more pages arrive, later passes may
   discover additional children or records. Complete preview assembly precedes
   semantic certification, not necessarily history arrival.
2. Route referenced unaccepted Changes through their ordinary validator. A general
   root waits for accepted history, including its original bootstrap and full
   represented ancestry. A page never grants an operation/action occurrence.
3. Prepare only requirements justified by the actual immutable inputs. Before
   replacing waits/removing ready work, recheck each requirement in one serialized
   SQL transaction. Already satisfied requirements are omitted. If none remain,
   keep/requeue the root for a fresh validation pass.
4. Otherwise commit the remaining exact-ID waits and remove its ready entry in
   that same transaction. Input arriving before the transaction is found by its
   recheck; input arriving afterward wakes the committed waits. Both orders finish
   without another network event. Requirements discovered during another pass
   replace that root's waits, not other candidates' entries.

Snapshot roots consume retained pages and accept the complete checked root/page
set together. Pages have no root back-reference and need not be accepted first.
Shared pages remain usable for another root if one root is rejected.

**R2 gate:** small delivery permutations, including arrival/acceptance during
parking, finish when the last exact prerequisite becomes usable. Status distinguishes
missing pages from retained-but-unaccepted history. Reopen preserves actionable
work and exact waits. An always-waiting implementation must fail a positive test.

### R3 — Complete acceptance, rejection isolation and lifecycle

- Reuse `CheckedSnapshotAcceptance` and S1's atomic acceptance path. Complete page
  coverage, exact occurrences, original bootstrap, action groups and all neutral
  continuation claims precede root acceptance. Recheck the live connection and
  collection/profile at the consumer. A later valid accepted prefix can coexist
  with a valid older cut; acceptance reads the current pin rather than restoring
  its captured value.
- Distinguish a root's own invalid manifest/claims from an unavailable or rejected
  prerequisite. Intrinsic child rejection blocks the root and names that child;
  it does not automatically reject the root or shared pages. A contradiction
  between valid child bytes and a root's asserted ranges/counts is checked against
  that root. Preserve unsupported inputs for diagnosis/future validators without
  promising that this version can accept them.
- Classify reads using accepted membership before interpreting metadata/body:
  positively missing or damaged required accepted evidence enters the damage
  path; unaccepted optional input failure remains candidate rejection/blockage.
  Distinguish a bad locator supplied by an incoming root from damage to its
  otherwise intact accepted target. Verify the target against its actual retained
  identity before attributing the failure; a misaddressed optional reference must
  not poison healthy accepted history.
  Repeated failure to record a damage marker cannot restore the live owner's
  healthy admission. I/O, ownership loss, cancellation, missing data and work
  deferral are separate from semantic rejection.
- Commit rejection reason and that object's ready/wait cleanup atomically. Failed
  recording leaves exact retryable input or a complete recorded rejection; neither
  outcome edits accepted history. Do not inherit a rejection into descendants or
  repeatedly select one rejected root ahead of unrelated valid work.
- Reuse condition-based validation resumption after finite save interference.
  Continue the owned attempt when saves cease; no new delivery/timer is required.
  Storage failure retains explicit retry/reopen behavior, not an infinite retry loop.
- Let an owned local write/acceptance transaction settle before releasing its
  resources. Missing pages/history cause durable parking, not a suspended network
  wait that holds the receiver or prevents close. Optional root verification can
  leave durable ready work for reopening when closing stops its preparation.
  Preserve S1's durable-quit rule and the existing cancellation/ownership contract;
  late completions report actual commits, never permission to publish into a new
  owner or clear a pending note generation.

**R3 gate:** authentic bad roots, unsupported prerequisites, shared pages and valid
unrelated history have distinct outcomes and eventual unrelated progress. Both
profiles survive repeated rejection/damage-recording write failures and restart.
Copied-store, closed-session and delayed-completion negatives reach actual consumers.

### R4 — Work/space qualification and fresh-process failures

Use the existing history worker and database actor, with synchronous transactions.
Bound encoded buffers, dispatch/read turns and concurrent preparation using existing
per-object limits and owned receive/construction reservations. Budget exhaustion
keeps a short-lived worker's assembly/traversal progress across a yield and resumes
it without another arrival. Durable ready/wait state supplies restart recovery if
that worker is lost. Avoid repeatedly restarting the same prefix merely because
its work exceeds one turn. A budget is not unsupported history or permission to
truncate notes, dependencies or continuation indexes.

Measure separately: envelope/page reads and decodes; membership audit and semantic
history visits; peak decoded capture/preview/graph storage; SQL/VM work; maximum
writer-turn/acceptance duration; and local-save completion latency. The complete
root/page acceptance transaction remains atomic. Yielding before it does not prove
that this final transaction is short: report its scaling and redesign/qualify the
specific bottleneck before claiming a bounded latency guarantee. Preserve direct
ordinary-save and healthy no-work startup read-count checks.

Run growing histories of 64/256/1,024 actions with fixed current notes; separately
vary page inventories and index depth, and exercise wide continuation state. Repeat
with smaller preparation budgets. Expected history/state stays identical, and
finite interfering saves are followed by progress without another arrival.
Temporary-envelope bounds do not imply constant total decoded memory.

Accepted history is retained indefinitely under v1. S2 preserves abandoned candidate
pages; it adds no automatic cleanup. Duplicate arrival stores no second byte copy.
Measure retained backlog as well as RAM and explicitly report ENOSPC/EIO. Never
acknowledge uncommitted retention, erase admitted inputs to make room, or call a
space failure successful quarantine. Untrusted-intake concurrency/outer-size limits
and later owned candidate cleanup are separate from a lifetime history cap.

**R4 gate:** deterministic work/progress checks and fresh children exercise the
actual public receive path and store opener. All committed inputs survive their
defined fault classes, and committed work is determined without callback logs.
Document actual resource measurements and remaining limits, not a nominal budget
that ignores the final acceptance transaction.

## Executable scenario matrix

Use real independently owned sender/receiver stores and exact envelopes for both
profiles. Start with two distinguishable notes and an untouched sentinel where
appropriate. Parameterize the bounded schedules; deterministic gates at actual
effects replace timing sleeps. Use `#require` for prerequisites/path witnesses.

Begin with all 24 delivery permutations of one root, two data leaves and one
history prerequisite, with their index page already retained as assembly input.
Add separate index-page-arrival, two-history-prerequisite and
shared-page fixtures with targeted cross-order/parking schedules. Sweep fault
cuts separately. This keeps disputed transitions observable without multiplying
every delivery order by every fault, history feature and platform.

| ID | Difficult schedule / companion | Independent observation and targeted production mutation |
| --- | --- | --- |
| RS01 | All 24 root/two-leaf/history delivery orders with the index retained first; separate index-arrival and two-prerequisite orders; duplicate each role separately. | Root accepted only with complete pages and accepted history; exact candidates/edges/pin retained once. Remove arrival wakeup or treat retention as acceptance. |
| RS02 | Page or history acceptance arrives after missing-input discovery but before/during/after parking. | No lost wakeup; the last delivery alone enables acceptance; intermediate requirements reflect their actual roles. Omit transaction recheck or split wait/removal. |
| RS03 | One missing page, then a deeper missing child; meanwhile history is retained but not accepted. | Named requirements survive reopen; later discovery stays correct and no root/page circular acceptance wait exists. Require page acceptance before assembly. |
| RS04 | Authentic bad root and valid root sharing usable pages; unsupported child and unrelated valid Changes. | Own rejection versus blocked prerequisite; shared pages and descendants preserved; unrelated work accepted. Propagate rejection or convert prerequisite failure into root rejection. |
| RS05 | Fail parking/rejection writes twice; crash before/after their commits and again during recovery. | Exact bytes plus retryable work or complete committed state; accepted history unchanged. Drop ready state or classify storage failure as invalid input. |
| RS06 | Snapshot represents E; its referenced accepted envelope contains complete E and F; branch R accepted before/after root. | Full E/F/R memberships and current values/context survive acceptance/reopen. Treat object membership as the represented operation cut or restore the old pin. |
| RS07 | Equal body but differing revision/head/scope, copied-source disposition, typed retirement, Restore or compensation claims. | Valid neighbors pass, one authentic semantic defect fails with unchanged Current/history. Skip a claim comparison. Follow with ordinary query/save to expose lost context. |
| RS08 | Omit an isolated accepted operation/action index row; separately corrupt accepted bytes, only an optional page, or misaddress an intact accepted target from an incoming root. | Required damage blocks editable success despite a usable snapshot; optional failure/bad reference remains isolated. Repeat marker-write failure. Omit membership audit or permit snapshot fallback past known loss. |
| RS09 | Copied equal-ID/equal-prefix store; close/reopen/save newer work while an old receive/acceptance completion is held. | Actual consumer rejects wrong connection/session; exact old commit survives and newer pending work stays owned. Omit context guard or consume snapshot result as save acknowledgment. |
| RS10 | Two real history checks interrupted by local saves; saves stop, including already-finished and held-completion orders. | Witness actual interference and later acceptance with no new receive; failed save retry handle remains owned independently. Drop resumption or wait on pending rather than active work. |
| RS11 | One valid standalone page, blocked root, then cancellation/quiesce/reopen; held transaction completion variants. | Pages remain assembly inputs, owned writes settle, optional unfinished work cannot add a durable-quit gate; reopening finds ready/wait state. Drop exact input or make optional work a close gate. |
| RS12 | Increasing history/page width, lowered preparation budgets, and candidate/acceptance ENOSPC/EIO/ambiguous sync. | Equivalent complete results, measured work/space, local-save opportunities, exact recovered identities and no premature receipt. Truncate for a budget or swallow commit uncertainty. |

RS06 tests retention/ordinary reduction only in S2. RS07 tests semantic certification
and existing queries, not a future snapshot installer. Register follow-through
fixtures for S4; do not relabel these passing companions as snapshot-based recovery.

Extend `SnapshotAcceptanceTests.swift`, add a focused received-snapshot suite if it
keeps responsibilities clear, and extend `test-storage-snapshot-process.py` plus
the probe with receive/status commands. Preserve existing S1/Phase 3 campaigns.
The standard qualification driver must require named discovery of every new gate,
both profile companions, reached fault hooks and the intended receive/parking/
acceptance transitions. Add no alternate permissive proof-construction route.

Inspect actual DB bytes, kind/locator metadata, accepted memberships/edges, current
pin, ready/wait/rejection rows and unchanged private groups. Extend the independent
wire/SQL inspector for unaccepted inputs and requirements. Independently expected
bodies, IDs and hidden relationships supplement validator agreement. A recovery
child receives surviving storage and normal selection/unlock inputs, never the
parent's expected graph, receipt log or in-memory waits.

Sweep termination before/after retention+wake, parking/rejection and complete
acceptance, then fail reopening a second time. Keep process termination, explicitly
modeled persistence loss and later corruption distinct. Inject real EIO/ENOSPC,
busy and ambiguous commit completions with fault-hit witnesses. Physical power
loss remains unqualified until separately tested.

## Language and model-backed checks

- Keep DB/statement resources actor-isolated on the existing blocking executor;
  transactions use synchronous closures. Transfer immutable owned bytes and
  checked `Sendable` preparation results through `@Sendable` workers. Every
  suspension before an effect has an actual applicability recheck.
- Keep evidence constructors issuer-private. Compile ordinary/sibling client
  challenges for page/preview versus semantic/durable evidence and snapshot versus
  save receipts. Test same-type wrong collection/profile/key, equal-ID copied
  connections and reopened sessions at their real consumers. Add no unchecked
  concurrency conformance or generic boolean-ready flag.
- Use exhaustive enums for input kinds, requirement roles and outcomes. Intrinsic
  unsupported data, dependency blockage, invalid claims, scheduling deferral,
  storage failure and required damage must not collapse into one rejection.
- The [receive models](../../tla/README.md) currently model accepted-parent wakeups
  and finite save interference, not standalone retained-page assembly. Their
  passing configurations are regression evidence, not proof of the arrival rule.
- Before closing S2, add a small focused bridge for retained-versus-accepted
  requirements and parking. Start with one root, two pages and two ordinary
  history prerequisites; a separate fixture adds two roots sharing a page and
  own rejection. Split discovery, park recheck/commit, arrival, history acceptance,
  full-root acceptance, close and crash/reopen. Keep SQL commit atomic and model
  its precommit work separately. One/two crashes or storage failures suffice for
  focused families; avoid a universal scheduling cross-product.
- Independently specify complete requirements, initial history and expected
  acceptance membership. Assert retained exact inputs, preserved prior history,
  complete root/page acceptance and queue accounting for actionable roots/Changes.
  Valid inert pages are a distinct modeled role. Check progress once supported
  prerequisites are usable and finite interference ends, with explicit fair
  processing and retry/reopen assumptions, not compulsory network delivery.
- Require arrival-during-parking, retained-but-unaccepted history, successful root
  acceptance and unrelated-progress witnesses. Mutations must catch lost arrival
  wakeup, stale parking, candidate-as-accepted, circular wait and inherited
  rejection at their designated property. Parse failure/timeout is no pass.
  Preserve earlier safety conditions; add page roles rather than weaken ordinary
  closure invariants. S4's outside-cut/install bridge has separate executed
  evidence in the [S3/S4 report](phase4-bootstrap-reconstruction-validation.md).

## Qualification and completion

Run debug/optimized Swift suites; independent fixtures and inspector self-tests;
schema equality/constraint tests; ordinary-client/sibling construction challenges;
targeted isolated mutations; and new/existing process campaigns through the
existing driver. Require a valid baseline, nonzero intended discovery and the
designated assertion for each mutation. Extend strict C-boundary/sanitizer checks
only where paths change; retain strict Swift 6.4 memory/concurrency diagnostics.
Qualify affected checks on macOS arm64 and Linux, then Intel/macOS 11 when available,
explicitly reporting unavailable environments without weakening contracts.

Record commands/source hashes, complete schedule bounds, named discoveries,
fault hits, mutation verdicts, independently observed membership/context, model
configurations and resource measurements in an S2 report. Planning changes alone
do not require rebuilding the application or rerunning unchanged models.

S2 completes when R1–R4 and RS01–RS12 pass through actual intake, parking, acceptance
and fresh-process consumers for both profiles, with the focused model gap covered.
Then proceed to S3's complete store-backed bootstrap and S4's all-branch rebuilding.
Their connected Delete/conflict/Restore/Undo/Redo and installation/crash assertions
remain mandatory; receiving a correct snapshot does not satisfy them.
