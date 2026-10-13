# Phase 5: dependency-ordered implementation plan

Updated: 2026-10-13

Status: P5.1 and P5.2 are implemented and qualified within their documented
capability and distribution limits.
See the [root-ownership](phase5/01-root-ownership-validation.md) and
[immutable-files](phase5/02-immutable-files-validation.md) reports for exact gates
and platform boundaries. P5.3's real local repository exchange is implemented
and [qualified within its documented limits](phase5/03-local-repository-exchange-validation.md).
P5.4's A–F adapter/driver increments are implemented and qualified within their
documented capability/distribution limits. The
[qualification ledger](phase5/04-apple-coordination-and-discovery-validation.md)
records local/platform checks, measured coordination cost, the approved fresh
deep-HFS+ limitation and passing final-source signed two-Mac exchange/reopen for
both profiles. P5.5's headless startup/association implementation is
[qualified within its documented limits](phase5/05-startup-and-root-reassociation-validation.md),
including completed component reruns, compiler/sanitizer/mutation checks and
signed two-Mac startup/reassociation for both profiles.
P5.6–P5.7 remain planned.

The P5.3 [bounded metadata and accepted-hint batch plan](phase5/bounded-discovery-batches-plan.md)
is implemented. Its [qualification report](phase5/bounded-discovery-batches-validation.md)
records native/SQL batching, race/failure checks and integrated measurements,
preserving the existing protocols before provider/host integration.

The [private-connection reuse increment](phase5/private-connection-reuse.md)
then amortizes fixed opening and physical ownership checks over that connection's
synchronous turns, while retaining commit, recovery and asynchronous-result fences.
Its report records the one-query-per-hint-group bound and platform qualification.

The expanded [P5.4 plan](phase5/04-apple-coordination-and-discovery.md) closes the
remaining P5.3 caller/scheduling connections, then orders real coordinated effects,
presenter settlement, automatic discovery/publication, availability/continuity
observations and signed two-Mac qualification. Its P54-* matrix extends the Phase 5
scenarios with actual-accessor, failure/restart, compiler and work-count gates.

The detailed [P5.5 plan](phase5/05-startup-and-root-reassociation.md) orders six
increments: closed health decisions, returning publication, exact named provider
waits, explicit creation/fresh bootstrap/private-loss entry, Retry/Re-open and
connected qualification. Its P55-01–24 matrix specifies real consumers, independent
observations, crash/recovery cuts, compiler/mutation challenges and work/platform
gates. It reuses existing required state and ownership; repair/copy effects remain
P5.6 and final application adoption remains Phase 7. The P5.5 ledger separates
completed production witnesses from ongoing final/platform qualification.

## Purpose and reading order

Deliver real rooted repository transport around the existing Swift storage engine.
Use the [Phase 5 testing plan](phase5-provider-root-testing-plan.md) for scenario
definitions, independent observations, fault classes and qualification rules.
This document orders the implementation that makes those witnesses executable.
The [Swift roadmap](swift-storage-implementation-plan.md#9-phase-5--provider-and-physical-root-adapters)
defines phase scope; the [conformance strategy](swift-storage-conformance-testing-strategy.md)
defines the TC-* contracts.

Read this index, the selected part and its referenced testing sections. Each part
names prerequisites, implementation work, language-backed boundaries, tests and
an exit gate. Preserve the [specification](../../iCloud-Drive-Support-Spec.md),
[ADRs](../../adr), [vocabulary](../../../CONTEXT.md) and
[model boundaries](../../tla/README.md). Parts are delivery units rather than
new protocol versions or product-policy decisions.

## Dependency order

| Part | Deliverable | Required predecessor | Testing-plan group |
| --- | --- | --- | --- |
| [P5.0 — Boundaries and harness](phase5/00-boundaries-and-harness.md) | Actual caller inventory, narrow adapter contracts, observers and reachable fault seams | Existing Phase 2–4 engine and reports | Preparation for 5A–5E |
| [P5.1 — Root ownership and execution](phase5/01-root-ownership-and-execution.md) | Continuously owned physical roots and independently executing provider work | P5.0 | 5A; foundation of 5C |
| [P5.2 — Immutable files and namespace](phase5/02-immutable-files-and-namespace.md) | Bounded rooted reads/catalogs and verified exclusive immutable installation | P5.1 | 5A |
| [P5.3 — Local repository exchange](phase5/03-local-repository-exchange.md) | Real disk publication/discovery/receive/reopen between independent stores | P5.2 | 5B |
| [P5.4 — Apple coordination and discovery](phase5/04-apple-coordination-and-discovery.md) | Production Foundation/provider adapter, invalidation/materialization and accessor lifetime | P5.3 | 5C |
| [P5.5 — Startup and root reassociation](phase5/05-startup-and-root-reassociation.md) | Integrated health/startup decisions, returning/fresh opens and explicit Retry/Re-open transitions | P5.4 | 5C; prerequisite of 5D |
| [P5.6 — Repair, replacement and copy](phase5/06-repair-replacement-and-copy.md) | Transparent repository repair, complementary private repair and physical source-preserving copy | P5.5 | 5D |
| [P5.7 — Connected qualification](phase5/07-connected-qualification.md) | Consolidated crash/race, privacy, scaling, OS and live-provider evidence | P5.6 and earlier gates | 5E |

The main implementation path is P5.0 → P5.1 → P5.2 → P5.3 → P5.4 → P5.5 →
P5.6 → P5.7. P5.3 supplies the first end-to-end milestone: **save → actual
repository files → second store → fresh-process recovery**. P5.4 repeats that
path through Apple coordination rather than treating API probes as its substitute.

Qualification starts with each part. Local ownership/filesystem jobs begin in
P5.1/P5.2; live API jobs begin in P5.4. Replacement primitive experiments for
P5.6 may begin after P5.2, and health decision-table tests for P5.5 may be written
before live inputs exist. Those preparations do not qualify their eventual
production callers or bypass the indicated exit gates. P5.7 consolidates evidence
and closes connected gaps rather than postponing all difficult tests until the end.

## Existing code to reuse

| Existing area | Reuse in Phase 5 | Remaining connection |
| --- | --- | --- |
| [LocalStoreSession](../../../NVStorage/Sources/NVStorageRuntime/LocalStore.swift), [receive](../../../NVStorage/Sources/NVStorageRuntime/ReceivedObjects.swift), [publication](../../../NVStorage/Sources/NVStorageRuntime/Publication.swift) | Owned private store, exact receive/parking/acceptance, catch-up and checked headless publication | Physical root/session fences, real discovery inputs and independent transport lifetime |
| [BootstrapCandidate](../../../NVStorage/Sources/NVStorageRuntime/BootstrapConstruction.swift) | Retained incomplete input and verified complete fresh-store bootstrap | Discover selected descriptor/root/pages on disk; no automatic bootstrap selection by filename/arrival |
| [CollectionCopies](../../../NVStorage/Sources/NVStorageRuntime/CollectionCopies.swift) | Exact accepted-history capture and saved-work/current-export distinctions | Bounded publication inventory and physical provider effect consumers |
| [RepositoryCopy](../../../NVStorage/Sources/NVStorageRuntime/RepositoryCopy.swift), [CStorageIO](../../../NVStorage/Sources/CStorageIO/NVStorageIO.c) | Rooted copy observations, owned destinations, barriers and lifetime patterns | Qualify shared-root ownership and strict final-object visibility separately from verified fresh-destination copy |
| [PrivateRepair](../../../NVStorage/Sources/NVStorageRuntime/PrivateRepair.swift), [StoreSelection](../../../NVStorage/Sources/NVStorageRuntime/StoreSelection.swift) | Salvage, validated union, fresh verified sibling and selection activation | Provider source acquisition, namespace preservation and real root reassociation |
| [NVRootedDirectory](../../../NVRootedDirectory.m) and [Foundation migration](../../Foundation-Safe-Replacement-Migration.md) | Descriptor-relative safety envelope, coherent snapshots and intent-specific replacement gates | Narrow Darwin bridge and separately qualified immutable/directory effects |

These are reuse points, not claims that their present APIs already implement a
live provider session. In particular, `retainedObject(at:)` reads one accepted
object, whereas `captureRepositoryHistory(through:)` presently builds a complete
captured copy. Routine background publication needs bounded selection rather than
using a whole-history array on every save or launch. Existing repository copy
and legacy absent-file helpers also include direct writes to a visible final;
their success does not establish strict immutable publication. P5.0/P5.2 qualify
the appropriate new use without rewriting unrelated successful Phase 4 work.

## Shared implementation rules

### Keep the boundaries small

- Keep Core's canonical values/validators platform independent. Reuse Runtime's
  database actor, sealer, receive queue and verification/recovery machinery.
- Own provider/root work separately from the database lane. Confine Foundation,
  bookmarks, coordinators and presenters to a narrow Darwin adapter. The v2
  proposal's `NVStorageApple` is an organizational candidate, not an existing
  target or permission to expose unchecked constructors across modules.
- Prefer compiler-isolated owners, immutable messages and closed outcomes. Use
  selective unique ownership where it simplifies descriptor/stage lifetime.
  Validate revocable authority at its consuming effect, including after suspension.
- Identify exact locally accepted publication inputs separately from parsed or
  parked input. Reuse exact sealed bytes and existing durable identities on retry.
- Reuse current SQL indexes and required private records. New state is principally
  session-local ownership, lifecycle, dirty/discovery progress and owned in-flight
  work. Any additional durable field/table must first demonstrate a missing
  recovery obligation; no separate outbox, permission registry or cloud ledger
  is assumed by this plan.

## Whole-system architecture

These maps connect the existing requirements to source responsibilities. They
guide the increments above; they add no protocol state or product policy.
The [initial caller inventory](phase5/00-caller-inventory.md) records the actual
reuse boundaries and the first implemented root consumer.

### Ownership and source boundaries

```text
Application collection owner (Phase 7; main actor)
    live notes, pending generations, admission, synchronous search
    │ immutable captures                    ▲ checked publication
    ▼                                       │
NVStorageRuntime / LocalStoreSession
    ├ DatabaseLane + its dedicated executor
    │    encrypted history, required private state, derived current rows
    └ existing preparation/history workers

RepositoryRootSession (P5.1–P5.3, in NVStorageRuntime)
    session lifecycle, generation, bounded in-flight work
    └ owned root lane + independent dedicated executor
         directory descriptor and continuous directory-object flock
         bounded rooted reads/discovery and staged exclusive immutable installation
         └ narrow Darwin coordination/presenter adapter (P5.4)

NVStorageCore: canonical values, codecs and pure validation/reduction rules
CStorageIO: audited descriptor-relative effects and final resource disposal
```

Keep the first root owner in Runtime to reuse its qualified executor and C
disposal pattern. A separate `NVStorageRepository` target remains an optional
later organization, not a prerequisite or reason to expose unchecked factories.
Core remains portable. Apple handles stay confined to the Darwin boundary.
Two independently executing resources matter more than two package names.

P5.2's `ImmutableRepositoryObject/Locator` factories bind exact checked bytes to
canonical destinations. File-private root evidence constructors and contextual
consumers stay beside the effect owner. `ImmutableInstallation` proves the exact
physical result and barriers; P5.3's bounded publication capture separately selects
accepted private history before invoking publication. Raw discovered leaves and local acceptance
receipts remain distinct types.

The root owner grants session-scoped effect permission through restricted
construction; the consuming effect checks the actual owner and current context.
Directory identity is local evidence, distinct from collection identity or a
portable note identity. Immutable observations may cross owners; raw descriptors
and mutable platform objects stay confined. Use selective noncopyability only
when it simplifies resource ownership. Experimental lifetime features are outside
the baseline.

One application collection owner eventually coordinates local and repository
sessions. Windows own selection/presentation, not another writable store. Keep
the existing headless `LocalStoreSession.publish` callback separate from the later
main-actor AppKit bridge: its present synchronous callback executes on the
database lane. P5 adds no editor, responder or search changes.

### Action and transaction map

| Boundary | Owner / required evidence | Completion and failure meaning |
| --- | --- | --- |
| Admit user action | Application owner; current admission/context and exact before/after inputs | Live notes and pending generations change together. Admission alone is not durable. |
| Capture and seal | Existing Runtime capture/sealer; immutable complete group and dependencies | Own exact bytes for retry; preserve newer pending generations. |
| Accept local or received history | Database owner; complete validation, exact objects and dependency closure | One SQL transaction retains bytes, membership, pin/frontier and wakeups. Only its actual outcome permits a local receipt. |
| Materialize Current | Database owner; guarded accepted prefix and complete reducer result | Separate derived-row transaction; failure requires catch-up/rebuild, not repetition of an accepted user action. |
| Publish to live model | Host owner; prepared inputs and final store/history/view/live fences | Apply complete proposed effects or recompute. A completion clears only its exact pending generations. |
| Install repository object | Root owner; locally accepted exact bytes and current physical permission | Complete private-to-provider transfer only after the required file/namespace barriers and exact verification. Upload is separate. |
| Discover and receive | Root owner captures bounded observations; Runtime authenticates/retains/validates | Incomplete inputs park durably; independent valid work proceeds. Arrival order never determines causal order. |
| Update plaintext projection (Phase 6) | Captured current intent, logical durability and exact source/file/root evidence | Physical effects have their own outcome; failure cannot undo the durable logical command or authorize a filename sweep. |

Neither live publication nor a SQL transaction promises a cross-file or cross-Mac
transaction. Repository installation and upload status cannot issue a local
durability receipt. The pending live model, immutable accepted history and derived
current rows each retain their existing distinct roles.

### Work priority, budgets and resumption

| Work | Execution / priority | Resumption / retained obligation |
| --- | --- | --- |
| Ordinary local save | Existing local database/preparation resources; priority over optional historical work | Save-settlement notifications resume postponed validation after finite interference. Exact admitted input remains owned. |
| Returning startup | Indexed current rows, required ready work, unfinished verification and accepted suffix | Editable publication waits for local requirements, not optional snapshots or provider inventory. |
| Historical validation / reconstruction | Existing bounded workers and short synchronous database turns | Yield on budget exhaustion, resume complete validation; exceptional rebuild may read history. |
| Optional snapshot work | Existing receive reservation after successful checked publication | Durable queue and existing wakeups; close retains unfinished work, persistent failure uses explicit recovery. |
| Discovery / publication | Separate bounded root resource; protocol-scoped enumeration and bounded byte capture | Dirty generations plus ordinary discovery opportunities close callback-before-visibility gaps; silence/high-water marks prove no completeness. |
| Materialization / provider access | Root/Darwin resource, bounded outstanding operations and retained inputs | Request acceptance is not completion. A held accessor keeps its resource until actual settlement; do not spawn unlimited replacements. |
| History / Undo / conflict query | Indexed selection and query-local envelope decoding | Load exact needed evidence lazily; unsupported/unavailable evidence disables that operation, not unrelated typing. |

Bound memory, descriptors, outstanding effects and work per turn. Budget exhaustion
yields rather than truncating dependencies or imposing a collection lifetime
limit. Healthy startup, ordinary saves, scoped queries, discovery and exceptional
reconstruction have separate performance measurements. A provider directory scan
can grow with its entries while remaining outside the local launch/save path.

### Failure, cancellation and close transitions

| Observation / transition | Local owner | Root/effect owner |
| --- | --- | --- |
| Provider unavailable, full or stuck | Healthy positively associated local editing/saving continues | Preserve pending exact bytes; stop/back off affected effects. Generic failure does not create Work Offline eligibility. |
| Positive unread newer/required provider evidence at startup | Apply the existing bounded wait and narrow Work Offline choice only with usable local closure | Retain that exact disclosure; later disclosure does not revoke already healthy editing. |
| Local barrier failure | Preserve admitted live work; suspend later admission and offer existing recovery | Provider progress cannot substitute for the local barrier. |
| Ambiguous commit / lost callback | Recover exact committed membership; retry the same sealed bytes | A late completion never grants a new session permission or overwrites newer pending work. |
| Invalid derived rows | Rebuild from validated retained evidence; preserve settings/private inputs | Independent provider status remains independent. |
| Missing/corrupt required history | Fence dependent publication; retain verification/damage obligations and repair from validated union | Preserve all available copies and foreign occupants; never turn loss into editable emptiness. |
| Invalid/unsupported incoming item | Retain rejection/blocking classification and exact bytes as specified | Preserve descendants and allow unrelated valid work; do not treat blocked descendants as intrinsically invalid. |
| Same physical root moved | Keep the same owned resource | Revalidate candidate equality; retain continuous lock and fence old captured permissions as appropriate. |
| Unknown/different root continuity | Retain healthy local ownership | Fence affected work. Retry rechecks the retained resource; explicit Re-open establishes a fresh association. |
| Cancel / quiesce | Retain admitted inputs and ambiguous transactions | Stop new effects immediately; entered work owns its handles until actual completion. Cancellation is not rollback. |
| Quit / switch / lock | Existing lifecycle owner sequences local barriers and required private state | Settle/defer projections, optionally wait for exact publication, fence/drain callbacks and observers, release ownership last. Local failure prevents successful quit. |
| Repair / Save As | Verify a fresh destination and pin before activation; distinguish full-history copy from current-only export | Revalidate source/destination generations, preserve originals and race winners; copy-only leaves active ownership unchanged. |

Use the existing [health matrices](../Implementation.md#provider-and-local-failure-behavior)
as the shared policy source. Adapters produce copied observations and closed
outcomes; presentation, Retry and repair consume those classifications instead
of independently assigning meaning to errno or provider brands.

### Security, evolution and observable contracts

Map sensitive data through decoding buffers, private rows, temporary files,
diagnostics, copies and backups. Authenticate before interpreting received
payloads; enforce bounded parsing even for authenticated input. Both private
profiles encrypt pages; provider output follows its explicit profile. Keep keys
and private pending snapshots out of repository publication. Password-free
recovery keeps its existing Keychain-independent contract.

Keep wire-format/reducer support, private schema compatibility and OS capabilities
separate. Preserve explicit unsupported outcomes and isolate epoch-4 import in the
Mac application. New source organization creates no additional development-store
migration obligation. Pin and qualify dependency changes independently.

At each boundary expose narrowly placed effect observations, held completions and
failure injection beneath the production issuer. Independent observers inspect
actual bytes, identities, barriers, pending work and fresh recovery. Test logs are
observations, never production recovery inputs. Compiler construction failures,
same-type/wrong-context consumers and targeted mutations complement those checks.

### Complete each increment with tests

For each changed boundary, require a valid companion, a near-valid/racing case,
actual production reachability, independent observed effects and its targeted
mutation. Use parameterized native Swift tests with isolated fixtures, existing
process/completion controls and the Makefile driver. Require nonzero discovery
and intended assertions. Keep simulated persistence loss, process termination
and later corruption separate.

Run narrow tests first, then affected debug/optimized, byte/schema/type/process and
mutation jobs. Add applicable C/memory/concurrency checks and available platform
witnesses as the code lands. Changes to shared app helpers additionally use the
native integration suite and `build.sh`; leave note interaction and UI untouched.
Models supply schedules and stated assumptions; rerun/update relevant configurations
when modeled behavior changes, preserving safety assertions. Documentation-only
planning does not require a full build or unrelated TLC campaign.

## Scenario ownership and progression

“First part” means the first required executable witness, not the last time that
case is run. Later parts repeat it through newly connected production consumers.

| Testing family / schedule | First part | Later required connection |
| --- | --- | --- |
| P5-ROOT | P5.1 | Apple events P5.4; reassociation P5.5; repair/close P5.6–7 |
| P5-CLEAN and installation failure sweep | P5.2 | Provider accessor and repair/copy callers P5.4/P5.6 |
| P5-DISC, P5-DELIVER, P5-LIVE; S1/S2 | P5.3 | Actual provider observations P5.4; combined qualification P5.7 |
| P5-CREATE | P5.3 | Startup/association consumer P5.5 |
| P5-REJECT | P5.3 | Real provider inputs P5.4; repeated repair/recovery P5.6–7 |
| P5-REPLAY; S5 | P5.3, local histories | Backup-root reassociation P5.5; three-writer connected run P5.7 |
| P5-COORD, P5-LANE; S6 | P5.4 | Re-open/repair ownership P5.5–7; local execution isolation starts P5.1 |
| P5-START; S3 | P5.5 | Live capability observations and final combinations P5.7 |
| P5-REPAIR, P5-COPY; S4 | P5.6 | Second failures and consolidated platform witnesses P5.7 |
| P5-PRIV and work/resource bounds | Every part introducing the corresponding effect | Whole-path sink/resource/scaling sweeps P5.7 |

## Scope, policy and final handoff

Both profiles use encrypted private databases. Preserve current history, action,
deletion, conflict-copy, compensation and snapshot-retention semantics; transport
does not add a reducer or reinterpret arrival order. Retain all final accepted/sealed
history and required descriptors. Healthy returning startup does not scan all
historical bodies, and local durability does not wait on provider progress.

The plan adds no shared mutable refs/WAL, remote acknowledgment requirement,
provider-specific storage policy, pruning, co-add or xattr identity scheme. Work
Offline retains its exact positive-disclosure startup policy. Unknown continuity,
upload status and matching paths/collection IDs grant no physical authority.

Keep plaintext projection/association/external-deletion decisions in Phase 6 and
AppKit/input/Undo/resolver/application lifecycle integration in Phase 7. Keep their
caller gates visible even when their physical primitives are exercised here.
Phase 5's headless status/transition APIs are not a finished user-facing flow.

Each part records its revision-bound results beside its plan or in a shared report
with clearly separate part sections. Mark completed, partial, unsupported,
inconclusive and unavailable qualification distinctly. A physical capability or
policy gap blocks only the affected claim; preserve its counterexample, continue
unaffected work and ask before changing predetermined contracts. Phase 5 completes
only when the [testing-plan completion gates](phase5-provider-root-testing-plan.md#11-reporting-and-completion-gates)
have production witnesses. Remaining distribution/security/physical-power-loss
qualification stays explicitly identified for Phase 8.
