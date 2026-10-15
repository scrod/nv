# P5.4 — Apple coordination, discovery and accessor lifetime

Updated: 2026-10-12. Status: implemented and qualified within the ledger's explicit
platform/capability boundaries. This document defines the required gates; their
executed evidence is recorded separately. Dependency: [P5.3](03-local-repository-exchange.md)
and its qualified batching/connection-reuse follow-ups.

Implementation/qualification status is recorded in the
[ledger](04-apple-coordination-and-discovery-validation.md). A–F have concrete
consumers and passing witnesses, including final-source real two-Mac exchange
for both profiles; that evidence remains distinct from local transport checks.

## 1. Outcome, authority and scope

Deliver this path through the production Darwin adapter:

**Durable local action → coordinated exact immutable installation → peer
coordinated discovery/read → durable receive/acceptance → checked headless values
→ fresh-process reopen.**

Follow the [specification](../../../iCloud-Drive-Support-Spec.md),
[ADR-0006](../../../adr/0006-retain-positive-association-and-directory-ownership.md),
[ADR-0013](../../../adr/0013-publish-exact-copies-of-durable-local-segments.md),
[vocabulary](../../../../CONTEXT.md) and [model boundaries](../../../tla/README.md).
The [Phase 5 testing plan](../phase5-provider-root-testing-plan.md) supplies
P5-ROOT/COORD/LANE/DISC/DELIVER/LIVE/REJECT/PRIV and connected schedules S1/S2/S6.
The [conformance strategy](../swift-storage-conformance-testing-strategy.md)
governs independent observations, fault classes, mutation controls and compiler
probes. Preserve the [Swift ownership/evidence design](../swift-storage-library-proposal-v2.md).

Check the [Apple API ledger](../../../Apple-API-Contract-Validation.md) and
[Foundation migration contract](../../../Foundation-Safe-Replacement-Migration.md)
for each actual consumer. Existing primitive probes inform assumptions; they do
not qualify this transport path. Investigate surprising results against documented
flags, actual URLs, intervals and independent observations before calling them an
API-contract violation.

This part supplies transport, observations and lifecycle handling. P5.5 retains
startup/Work Offline decisions and root reassociation; P5.6 retains repair/copy;
Phase 6 retains plaintext projection reconciliation; Phase 7 retains application
UI integration. Existing-file replacement, Apple historical-version disposition
and credential transitions keep their separate qualification gates. The adapter
uses the selected user directory rather than requiring an iCloud container.

## 2. P5.3 closure and source baseline

P5.3's [local exchange](03-local-repository-exchange-validation.md),
[bounded metadata/accepted-hint groups](bounded-discovery-batches-validation.md)
and [private-connection reuse](private-connection-reuse.md) are qualified within
their recorded limits. Preserve those gates; the remaining work is connecting
their consumers to real coordination and actual scheduling sources.

| Reuse | P5.4 connection or remaining check |
| --- | --- |
| `RepositoryRootSession`, private `RootLane`/`RootLease`, native rooted effects | Put the actual effects inside the documented access interval; retain continuous physical ownership and the independent executor. |
| `RepositoryPublicationBatch`/cursor and exact accepted bytes | Add a bounded caller that advances only completed batches, retries exact input and starts incremental subsequent passes. |
| `discover`, nested streams, invalidation and buffered-name refresh | Connect presenter/ordinary opportunities to an actual driver. `RepositoryDiscoveryOpportunity` currently labels an explicit call; the enum itself schedules nothing. |
| Batched accepted-file hint lookup | Keep one indexed lookup per eligible metadata group, fresh native observations and accepted-membership checks. An unchanged hit still needs no old body read. |
| Checked persistent private connection | Keep fixed schema/header/key checks at connection opening and short physical/context fences at relevant turns. Coordination adds no reason to reopen/revalidate the whole database per item. |
| Durable receive, parked bytes, wakeups, rejection and automatic validation resumption | Reuse them after copied bytes leave the accessor. Exercise failure/restart through the connected adapter instead of adding a transport journal. |
| Explicit selected-collection bootstrap | Deliver descriptor/root/pages/import closure to that existing connection. P5.5 owns the complete startup decision. |

Before coding, update [the caller inventory](00-caller-inventory.md) with each new
entry point, suspension, owner, effect and completion. Any proposed hint seeding
from publication or suppression of repeatedly rejected observations must preserve
the existing accepted-membership requirement and retained retry input; add it only
if measured work justifies the extra branch. It is not a prerequisite for 5.4.

## 3. Architecture and compiler-backed boundaries

Keep `RepositoryRootSession` as the control owner and the existing private root
lane as the blocking resource, separate from SQLCipher and history preparation.
Start with a narrow Darwin-conditional implementation in Runtime; splitting out
`NVStorageApple` is optional organization, not a reason to expose constructors.
Core and portable local transport retain their platform-independent contracts.

Use these boundaries:

- Actor-isolate lifecycle, generation, admission and in-flight reservations.
  Reserve before suspension and validate the actual operation after resumption.
  Actor isolation does not preserve assumptions across `await`.
- Confine coordinator/presenter/native handles to their owning adapter. Transfer
  copied immutable `Sendable` observations, sealed bytes and closed outcomes.
  Keep resource disposal on the owning execution resource.
- Prefer concrete synchronous effect entry points and a nonescaping scoped
  accessor helper. Issuer-restricted access evidence belongs to that lexical
  interval and root operation; it grants no permission after the accessor returns.
  Prove callback sendability/isolation against the actual imported SDK first.
- Restrict checked-result construction to private/file-private issuers. Preserve
  existing store incarnation, root session/generation, object and target-owner
  checks at their consumers. Same type and collection ID alone are insufficient.
- Use exhaustive states for waiting, entered, fenced and settled work and for
  observed continuity, availability and effect outcomes. Keep provider identity,
  physical root identity, local store identity and immutable object locators distinct.
- Use selective unique ownership where it simplifies descriptors/replies. Avoid
  broad `@unchecked Sendable`, public raw evidence factories, callback-to-actor
  blocking waits or a generic backend that lets clients fabricate successful effects.

Reuse existing progress/generation/cursor state. New transient state is limited
to the presenter registration, a synchronized presented-URL snapshot, the owned
coordination operation/reply resources, and one coalesced driver reservation/wakeup
if the existing owner has no suitable idle-work source. No new persistent table,
sidecar, outbox, permission registry or long-lived validation cache is planned.

## 4. Implementation sequence and per-increment gates

### 5.4A — Close caller gaps and establish real-accessor test seams

1. Inventory remaining P5.3 callers using §2 and record actual sources for open,
   hints, publication, resumed work, foreground/refresh and close. Keep database
   captures outside filesystem access intervals.
   Map every native intent to its coordination URL(s), flags and allowed effects:
   directory metadata/listing, exact body read, owned stage creation/write,
   add-only parent creation, final rename and verification/barriers. Qualify the
   combined/batched API where needed instead of assuming a parent-directory
   interval coordinates arbitrary descendant access.
2. Prototype the smallest coordination wrapper under strict Swift 6.4 and the
   minimum deployment target. Confirm documented threading, reentrancy and
   callback requirements before choosing isolation or bridging mechanisms.
3. Add test-only holds beneath the real wrapper: before request, actual accessor
   entry, before native effect, after effect, before delivery and final settlement.
   Confirm entry through a pipe/observer before any dependent test action.
4. Extend the signed LaunchServices harness to invoke production Runtime entry
   points. Keep ordinary host-free Swift Testing cases as the deterministic tier.

**Gate:** valid coordinated read/install companions, an independently observable
entered accessor, strict compiler/construction probes, and unchanged P5.3 baselines.

### 5.4B — Coordinate exact rooted effects

1. Wrap rooted metadata/discovery, body reads and immutable installation with the
   appropriate documented options. Use the accessor's actual URL and positively
   check its correspondence to the continuously owned root before an effect.
   A moved same-object root and a replacement at its old path are separate cases.
   Give each admitted operation a fresh coordinator confined to its documented
   execution context; cancellation is the separately documented cross-thread call.
   Preserve descriptor-relative addressing through ancestor moves and long paths;
   explicitly qualify the Foundation seam rather than silently reintroducing a
   `PATH_MAX` or guessed-path authority assumption.
2. Complete native I/O inside that interval. Copy observations/bytes out before
   expensive decoding, crypto, SQL lookup, receive/acceptance or host publication.
   Neither a detached task nor a retained permission extends coordinated access.
3. Keep metadata batches metadata-only and bounded. A database hint miss starts a
   separate body-read interval with fresh matching checks. A batch does not freeze
   child files; refresh buffered tails across turns. Do not replace the bulk native
   path with per-file Foundation queries merely to introduce coordination.
   Normal directory coordination is not recursive child exclusion. Use the
   documented per-item or combined access contract for actual reads/install effects;
   batch-preparation completion alone is not a grant for later I/O.
4. Reuse P5.2's exclusive staged immutable installer, exact-byte readback and all
   file/namespace barriers. An equal existing final follows its existing barrier
   path. Preserve collisions, partial effects and owned stages in typed results.
   Retain the verified stage's open descriptor between grants in a file-private
   noncopyable root-executor lease. Metadata-only timestamp changes between
   grants preserve this physical binding; exact stable bytes, link count, named
   source identity and final snapshot/barriers are rechecked before completion.
5. Distinguish coordination failure before access, entered-effect failure and
   stale completion. A failed required Darwin coordination path does not silently
   become an uncoordinated write. Retry uses the same accepted sealed bytes.

**Gate:** P54-01–04 and P54-18 below pass through actual effect consumers, including
no-effect checks on stale/replaced context and local/private performance baselines.

### 5.4C — Presenter registration, replies and settlement

1. Own one presenter per root, balance registration/unregistration and reserve an
   initial discovery opportunity independently of callbacks. Its reply queue must
   remain runnable while a provider accessor blocks the root lane.
2. Implement the presented-URL getter as a small thread-safe snapshot: Apple may
   call it outside the presenter operation queue. Keep remaining mutable control
   actor-isolated. Document the narrow synchronization wrapper and audit it.
3. Initialize each operation's coordinator with the owned presenter, suppressing
   ordinary self-notifications while keeping other presenters and version events
   active. The root lane owns initialization and synchronous access; the separate
   reply queue remains runnable. Apple's initialization-queue guarantee for moves
   applies when initialization shares the reply queue. This adapter instead uses
   its system reference, continuous physical ownership and final granted-URL/root
   checks for move safety. Preserve the existing operation reservations alongside
   the common presenter/purpose.
4. Invoke supplied relinquishment blocks and completion replies promptly and once
   according to each method's contract. Reacquisition callbacks are distinct from
   replies. The presenter represents immutable repository transport, so it need
   not wait for unrelated live-note saving, decryption or database work to reply.
5. Route ordinary subitem changes to scoped dirty hints. Root uncertainty fences
   effects until existing positive continuity checks succeed. Preserve the native
   root-loss latch; child hints alone must not repeatedly restart the whole session.
6. Distinguish cancellation before entry from an accessor already running. Fence
   late results, but retain its buffers, handles and capacity until actual return.
   Close/quiesce accounts for entered work honestly; local durable saving continues
   independently. Unregistration alone is not settlement of every queued callback.
   Logical fencing must remain runnable while the blocking lane is held. Any
   cross-thread cancellation bridge exposes only that documented capability,
   retaining the operation until settlement rather than transferring its handles.

**Gate:** P54-05–08 and S6 establish local commit while an actual accessor is held,
exact replies, rejected stale results and final resource baselines under sanitizers.

### 5.4D — Connect bounded discovery and publication resumption

Use one session-owned coalesced driver around existing methods, rather than a new
queue of semantic operations. Preserve each existing cursor's consuming checks.

| Actual source | Driver responsibility |
| --- | --- |
| Open/registration | Reserve first discovery and accepted-publication passes. |
| Presenter/vnode/FSEvents hint | Mark applicable discovery dirty; coalesce repeated hints without assuming listing visibility. |
| Bounded pass has remaining work | Schedule its next turn; retain parent/child progress and refresh unread buffered names. |
| Local save or receive work settles | Wake postponed validation and applicable publication/discovery through existing completion notifications. |
| Foreground, refresh or ordinary background opportunity | Start/revisit applicable passes even if the prior listing was empty and no callback followed. |
| Persistent I/O failure or close | Preserve durable work, stop overlapping attempts and follow existing retry/recovery/lifecycle outcomes. |

Advance publication cursors only over completed handoffs. Keep an incomplete
batch's exact bytes for retry; use the existing incremental next-pass capture
instead of a full-history capture on every hint/save. Restart reconstructs work
from accepted membership and retained receive state, not a persisted scan cursor.

After a nonempty publication batch, continue the indexed drain until an empty
pass observes the current accepted prefix. This preserves saves admitted while
an earlier frozen prefix traversed several batches: advancing to its continuation
must not consume the only demand for a later prefix. The terminating empty pass
adds bounded indexed bookkeeping, with no historical body decode or additional
stored flag. P5.7 qualifies the actual multi-batch/notification schedule.

Make idle discovery opportunities concrete. Prefer existing owner work sources;
if a headless idle owner has none, use one cancellable session-owned monotonic
wakeup with bounded cadence/backoff. Record its latency/idle-I/O tradeoff. A test
that repeatedly calls `discover` itself does not qualify automatic resumption.
Missing callbacks require revisits, not a guarantee of visibility by a deadline.

Apply the [adopted budgets](../remaining-storage-validation.md#resource-limits-and-scheduling):
default discovery turns of 16 entries, at most 64; bounded body/decode concurrency;
three attempt starts (initial, then 1 s and 4 s) within the 15 s attempt deadline
where that retry policy applies. An entered accessor that has not returned keeps
its capacity after a deadline; no overlapping replacement starts. Persistent
storage failure takes the existing explicit recovery/retry path rather than
automatic polling. Recurring ordinary discovery is distinct from that error retry.

**Gate:** P54-09–12 and S1/S2 pass with no new delivery/hint after interference ends,
and with work/resource counts bounded through repeated failures and restart.

### 5.4E — Supply availability, materialization and continuity observations

1. Return typed observations separating readable local bytes, disclosed dataless
   items, download/upload status, generic errors and unknown continuity. Status
   is supplemental; actual coordinated reads and rooted context remain decisive.
   Use selected-item APIs without a mandatory `NSMetadataQuery` or Spotlight
   dependency. A negative provider probe does not prove a local-only directory.
2. Request materialization only for bounded, specifically disclosed needed items.
   Request success is not download completion. Observe resulting availability and
   revalidate root/session and the exact read; avoid downloading unrelated notes.
   An evicted provider copy already accepted locally is not local required loss.
   Choose the documented request API only where its applicability is established;
   other providers retain explicit unavailable/unknown observations and ordinary
   coordinated-read behavior, rather than an assumed iCloud-specific capability.
3. Balance applicable security-scoped access and supply bookmark/file-reference/
   presenter URL candidates to positive physical comparison. Persisted association
   changes and user-facing Retry/Re-open transitions remain P5.5 work.
4. Where available, qualify forward provider evaluation under AV-09. Equal,
   changed, unknown, unavailable and unsupported outcomes keep their existing
   meaning. Reverse lookup/domain enumeration remain unnecessary for root loss.
5. Exercise these copied inputs at consumers and preserve P5.5's decision boundary:
   generic offline/full/coordination errors do not become absence, replacement
   permission or Work Offline eligibility.
   A protocol-looking filename alone establishes neither validated history nor
   newer/required evidence; keep raw disclosure distinct from that classification.

**Gate:** P54-13–15 pass. Any unavailable live stimulus is recorded as inconclusive
and remains an explicit qualification boundary, not a simulated API capability.

### 5.4F — Repeat exchange through signed, real provider consumers

Run bootstrap, ordinary edit/Delete, concurrent changes and general-snapshot
dependencies through the signed production adapter on two Macs in both directions,
for both profiles. Require the peer to read and accept exact bytes, then exec a
fresh reader with normal selection/unlock inputs. Inspect retained bytes,
membership, current values, history/context and pending work independently.

Record actual provider visibility and callbacks separately from controlled
missing/early-hint schedules. Perform only safe, owned-fixture disruption; do not
reset accounts or fill the user's cloud quota to manufacture a stimulus.

**Gate:** P54-16–18, connected schedules and platform checks below. Finish with a
qualification report distinguishing passed, failed, unavailable and unqualified.

## 5. Scenario and independent-observation matrix

These P54-* IDs expand the existing Phase 5 families; they are implementation
witness IDs rather than new product contracts. Each row requires a valid
companion, confirmation that the difficult production transition was reached,
a precise failure classification and an independent forbidden-effect check.
Exercise both profiles where bytes/durability/privacy differ. Use small bounded
combinations at semantic boundaries instead of crossing every OS with every fault.

| ID / existing family | Schedule through the production consumer | Required independent observation |
| --- | --- | --- |
| P54-01 / ROOT, COORD | Move owned root/ancestors, including long paths; recreate old path with identical collection bytes; change accessor URL before effect; invalidate while waiting. | Native identity/contender checks show effects only on the applicable owned object. Replacement bytes survive unchanged; late evidence is rejected by the actual consumer. Same-object move companion succeeds. |
| P54-02 / DISC, COORD | Metadata-only batch, hint lookup held, child safe-save/replace/delete, buffered tail after EOF, then body read. | Metadata phase reads no bodies. Fresh read detects changed context; copied bytes are coherent or classified changed/unavailable. Exact native observation counts and one hint query per eligible group remain bounded. |
| P54-03 / DELIVER | New install, equal existing final not yet proven durable, different bytes/kind, failure at stage/readback/rename/namespace barriers. | Exact final bytes, native barrier trace and accepted membership distinguish verified, not-installed and uncertain effects. Preserve competing entries/stages and retry the same envelope. |
| P54-04 / COORD, PRIV | Error before entry; error after partial effect; malformed error payload; cancel at handoff. | No access without a usable interval; partial effects are accounted for rather than reported absent. Real logs/stages contain only profile-permitted data. |
| P54-05 / LANE, S6 | Hold an actually entered read/install accessor; admit edit and then Delete; commit/reopen private store before release. | Exact local bytes/action membership and fresh current values establish local durability while the provider is held. No private queue/host callback waits for provider completion. |
| P54-06 / ROOT, LANE | Cancel before entry and during entry; expire deadline; quiesce/close/switch attempt; finally release; repeat close. | Count live coordinators, descriptors, stages, buffers and reservations. No reuse before settlement, double completion or stale consumer effect; resources return to the established baseline. Report any still-entered work honestly. |
| P54-07 / COORD | Independent coordinated reader/writer, own publication notifications, relinquishment/reacquisition, save/deletion accommodation and reentrant hint delivery. | Required blocks/replies occur once on documented queues without database/crypto waits or circular synchronous waits. Peer operation progresses after release; duplicate self-hints cause no repeated logical effect. |
| P54-08 / ROOT, COORD | Concurrent presented-URL getters, same-object move, registration/unregistration and callbacks queued before close; second local contender. | Thread sanitizer/stress checks the URL snapshot and actor handoff. Balanced registration and ownership remain observable; callbacks after retirement cannot retarget/reopen the session. |
| P54-09 / DISC, S2 | Hint before visibility, empty pass, later new writer directory, high child before low parent; send no further hints or explicit `discover` calls. | Actual driver revisits, retains exact child/parent bytes and accepts once when readable. Pipe/event trace proves the automatic opportunity, not a loop in the test, caused progress. |
| P54-10 / DISC | Coalesced hint storm, missing/asymmetric FSEvents, repeated unchanged rejected neighbor, interrupted nested passes. | Bounded live resources/turns, preserved parent progress and eventual valid-neighbor discovery. Hints prioritize checks; neither missing events nor a quiet interval proves absence/completeness. |
| P54-11 / DELIVER, REJECT | Descriptor after encrypted child; root before pages; multiple prerequisites; shared envelopes, renamed duplicates/repackaging, rejected prerequisite beside valid work. | Exact retained inventory and indexed waits/accepted closure; complete action effects once. No partial editable bootstrap, wholesale descendant rejection or poisoned ready-work loop. |
| P54-12 / LIVE, S1 | Hold receive preparation/result, edit/Delete locally, release; repeat with equal body but changed represented inputs; then cease edits without new files. | Durable remote action survives; newer live values/pending generations remain. Existing resumption recomputes after finite interference and publishes only applicable checked state. |
| P54-13 / START inputs | Observe named placeholder/unread newer object, request materialization, delay/fail/complete; evict provider copy already retained locally. | Record real availability and exact subsequent read. Request success/upload status never substitutes for readable bytes or remote acceptance. Supply truthful inputs for P5.5; preserve usable local closure. |
| P54-14 / ROOT, AV-09 | Bookmark stale/missing; forward identity equal/changed/unknown/unsupported; callback arrives after root generation change. | Consumer rejects stale results; positive physical comparison remains necessary. Generic errors/unknown identity grant no continuity, overwrite, absence or offline permission. |
| P54-15 / ROOT | Owned fixture becomes dataless/unreadable, permissions or kind change; contention; owned test volume detach/remount. | Actual root-loss/permission/capability classifications and native identities remain distinct. Preserve local private saves and known contention; no silent authority transfer to remounted/replacement paths. |
| P54-16 / DELIVER, REPLAY | Signed two-Mac bootstrap/edit/Delete exchange, concurrent branches, general snapshot retention parents, both directions; restart peer with normal inputs. | Peer exact envelopes, accepted IDs/closure, birth/deletion state, alternatives, Undo candidates and authoring context match independent expectations. An upload flag or sender success cannot pass this row. |
| P54-17 / REJECT, S1/S6 | Crash at reachable handoffs/barriers/retention/acceptance/catch-up; fail rejection recording repeatedly; crash again during recovery. | Fresh process receives neither expected-value oracle nor callback log. Surviving store/files show complete committed work or retained retry input; unrelated work resumes after storage recovery. |
| P54-18 / PRIV, work bounds, AV-12 | Synthetic secret/path markers; grow unrelated history and files; unchanged repeat scans/reopen; held/canceled operations; unavailable/excluded Spotlight. | Inspect actual sinks and byte inventory; count catalog calls/entries, native observations, SQL executions, envelope decodes, resources and separate local/provider latency. Preserve batching/connection-reuse and Spotlight-independent progress. |

Add multi-event cases selectively: P54-01+06 (move during cancellation),
02+09 (hint-before-visibility with a buffered tail), 05+12 (held accessor plus
newer live generation), 11+17 (blocked input plus failed recovery), and
13+16 (delayed materialization during real peer exchange). These connect the
evidentiary chains most likely to conceal data loss or mistaken authority.

## 6. Failure exploration, static checks and model correspondence

### Executable failures and observations

Use the existing driver, independent Node/native inspectors and fresh-process
probes. Extend them rather than adding another success-flag oracle. Record exact
stage reached, entry/completion counts, selected contexts, byte inventories and
diagnostic category. Keep fixtures owned, synthetic and isolated per test; run
Swift Testing cases in parallel unless a particular native volume/peer resource
requires a documented serialization boundary.

Enumerate reachable cuts around request/entry/effect/barrier/return/handoff and
the existing receive transactions. Do not invent a partially completed atomic
rename or pretend process termination is physical power loss. Keep process crash,
simulated persistence loss, later corruption, injected I/O failure and actual API
failure distinct. At selected cuts, inject a second failure during recovery.
Test EIO/ENOSPC, denied access, coordination errors, cancellation and unsettled
completion; never change ambiguous effects into a known rollback for convenience.

Require event-driven evidence for eventual progress and a finite watchdog for
test termination. The watchdog is not proof an OS accessor stopped. Cleanup of
owned temporary stages follows P5.2's qualified rules; preserve foreign/displaced
artifacts and all accepted/retained history. Keep testing interruption cleanup
separate from deleting fixture directories between runs.

### Compiler and same-type/wrong-context checks

Extend ordinary-client and actual-module negative compilation probes to challenge:

- Forged accessor scope, installed result or checked observation construction.
- Native/non-`Sendable` handles escaping isolation; actor state changed from a
  presenter callback; suspension or escaping captures in synchronous effect scope.
- Unrestricted copying of uniquely owned resources where noncopyable ownership
  is selected, and incompatible evidence types passed to final effect consumers.
- Missing exhaustive handling of lifecycle/coordination/availability outcomes.

Keep strict concurrency, strict memory safety and warnings-as-errors. Runtime
tests obtain real evidence from two stores/sessions and pass the wrong one to
the actual consumer; compilation rejection cannot prove revocable applicability.
If the SDK necessitates one imported-object synchronization bridge, confine and
audit it, demonstrate why compiler isolation alone cannot express that contract,
and cover it with stress/TSan and construction probes. Broadly disabling checks
or weakening Linux contracts requires human approval.

### Targeted mutations

Challenge stale accessor URL/root, effect after accessor return, metadata-only
body reads, omitted final barriers, shared provider/private execution, missing
actual entry, premature disposal, double/omitted presenter reply, lost initial or
post-empty wakeup, cursor advance over failed publication, request-as-availability,
dropped rejection input and plaintext diagnostic fallback. Pair each with a valid
control, required nonzero discovery and the intended independent failing assertion.
Tests that avoid the accessor or return unsupported do not qualify its consumer.

### Models

Reuse `RepositoryDiscoverySafety`, `RepositoryMetadataBatchSafety`,
`LocalDurabilityLaneIndependence`, `ReceiveResumptionSafety`,
`ReceiveRejectionSafety` and the SQLite acceptance/fast-start models. Update
correspondence to the concrete driver, scoped effects and settlement boundaries.

Add a small accessor/session scheduling companion if needed to cover the new
composition: two root identities, one or two work items, request/entered/fenced/
settled states, callback/visibility order, finite local-save interference and
restart. Assert no replacement-root effect, no early resource reuse, local save
independence and resumed applicable work. Keep API delivery/return fairness
explicit: local progress while an accessor is stuck is required; completion of
an accessor that never returns is not promised. Preserve existing safety conditions
and examine genuine counterexamples as potential spec defects. Run only affected
configurations when implementation changes modeled behavior; this plan alone
requires no TLC rerun.

## 7. Performance, OS and API qualification

### Work and latency gates

Repeat the [same-file bulk-scan comparison](directory-scan-performance.md),
[integrated batch measurements](bounded-discovery-batches-validation.md) and
[persistent-connection baseline](private-connection-reuse.md), using equivalent
file populations and both profiles. Measure metadata phase, hint SQL, body reads,
receive, publication selection, coordination waiting and native work separately.

- Keep native bounded bulk metadata and fresh tail observations; add coordination
  per meaningful bounded interval rather than per unchanged hint hit.
- Require one hint lookup per eligible group, no body decode for unchanged accepted
  hits and no repeated fixed schema/open checks. Keep all mutable context fences.
- Grow unrelated history through 64/256/1,024 actions with fixed new work. Outgoing
  selection uses bounded indexed captures; discovery catalog work may grow with
  entry count, but old bodies are not replayed on every scan or launch.
- Count idle wakeups, CPU/I/O, discovery latency and peak descriptors/buffers during
  hint storms, delayed availability and close. Document chosen cadence/backoff and
  any measured overhead rather than asserting constant total discovery work.
- Measure local admission-to-barrier latency while real coordination is held.
  Healthy private current-row startup remains independent of a provider-wide
  enumeration or upload wait; full startup decision integration is P5.5.

### Platform/capability matrix

| Environment | Required qualification and explicit limit |
| --- | --- |
| Current arm64 macOS / Swift 6.4 | Debug and optimized suites; signed LaunchServices harness; real coordination/presenter stimuli; affected mutation/type/schema checks and ASan/TSan, including native wrappers. |
| Intel Mac Mini / macOS 14.8.9 | Real signed adapter and two-host exchange; holds, moves, lifecycle, materialization/eviction observations and fresh-process recovery. |
| Intel Orbb / macOS 11 | Minimum-runtime executable for new adapter entry points and existing root/local-store companions. Record runtime separately from SDK/Swift Testing availability and the documented compiler/deployment workaround; it does not qualify default distribution packaging. |
| Ubuntu arm64 / Swift 6.4 | Portable exchange, strict compiler/evidence checks, driver/resumption, fault tests and ELF qualification; Darwin absence remains explicit, not substituted Apple coverage. |
| Owned APFS/HFS+ images; unsupported-volume companion | Production Foundation ownership/effect capabilities, move/detach/remount and strict unsupported outcomes. Qualify deep acquisition and moves separately with `test-storage-root-volumes.py --deep-root`. Fresh deep-HFS+ opening may explicitly report the approved exact safe refusal, with independent unchanged bytes/namespace/identity and released ownership; it is recorded as a limitation rather than successful opening. Ordinary HFS+ access, already-owned deep moves and APFS deep acquisition remain required. Short-path/native-only passes cannot replace those witnesses. Successful legacy export on another filesystem does not qualify immutable publication there. |
| Real iCloud Drive on two Macs | Exact peer read/acceptance in both directions. Report provider, OS, architecture, signed identity, launch method, root type, observed availability and callback trace without secret/path leakage. |

Guard newer APIs at runtime as required; SDK declarations alone do not establish
backdeployment. Extend the Apple ledger with actual flags, accessor context,
errors and independent observations. Count placeholder/eviction/offline/full
stimuli only when observed; distinguish API unavailable, failure to induce the
state and a failed behavior check. Provider status and forward identity remain
supplemental when unavailable. Physical power-loss qualification stays separate.

## 8. Completion and handoff

Record the implementation, exact commands/counts, mutation sensitivity, platform
exceptions, performance and unresolved qualifications in
`04-apple-coordination-and-discovery-validation.md` beside this plan.

P5.4 completes when:

1. Production coordinated read/install/receive consumers pass §5, not merely
   primitive probes or an alternate mocked transport.
2. Local durability succeeds while a real accessor remains held, and cancellation,
   presenter teardown and close preserve exact context/resources until settlement.
3. The actual driver resumes discovery/publication after finite interference and
   early empty visibility without requiring another hint, new file or restart.
4. Independent byte/membership/current-state checks, compiler boundaries, mutations,
   privacy and performance gates pass, including the required two-Mac production
   exchange. Unavailable supplemental capabilities retain explicit unknown/outcome
   coverage; an unavailable required witness keeps its qualification gate open.
5. P5.3's accepted-byte, batching, private-connection and recovery guarantees remain
   intact, with no new persistent transport state or weakened policy.

Then hand copied health/continuity evidence to P5.5 for startup/reassociation;
P5.6 consumes the qualified effects for repair/copy. Ask for a product decision
only if a demonstrated capability conflict makes the adopted behavior impossible;
do not silently reinterpret absence, deletion, Work Offline or source preservation.

## Primary API checks

Consult the installed SDK headers and Apple's current documentation while
implementing: [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator),
[cancel](https://developer.apple.com/documentation/foundation/nsfilecoordinator/cancel()),
[NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter),
[presentedItemURL](https://developer.apple.com/documentation/foundation/nsfilepresenter/presenteditemurl),
[presentedItemOperationQueue](https://developer.apple.com/documentation/foundation/nsfilepresenter/presenteditemoperationqueue)
and [coordinator initialization](https://developer.apple.com/documentation/foundation/nsfilecoordinator/init(filepresenter:)).
Their contracts guide the API seams; production-path observations qualify their
actual NV consumers.
