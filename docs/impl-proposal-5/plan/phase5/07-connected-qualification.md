# P5.7 — Connected qualification and Phase 6 handoff

Updated: 2026-10-14. Status: **implemented and qualified within the recorded limits**.
The [execution ledger](07-connected-qualification-validation.md) separates passing
witnesses, reused evidence and later release obligations. It maps this plan's
full matrix to the actual results, including a discovered publication-driver
defect, its regression and final platform requalification.
Dependencies: P5.1–P5.6, whose completed witnesses retain their recorded source,
platform and capability limits. This plan completes Phase 5's headless storage /
repository qualification, not the application's UI or release qualification.

## 1. Outcome, authority and scope

Connect the implemented paths where data can be lost: retained input becoming
accepted history, acceptance becoming current rows, delayed results meeting newer
edits, interrupted recovery acquiring fresh ownership, and a prepared copy becoming
the selected store. Reuse component qualification; test the connections it does
not establish.

Follow the [Phase 5 testing plan](../phase5-provider-root-testing-plan.md),
[conformance strategy](../swift-storage-conformance-testing-strategy.md),
[Swift boundary proposal](../swift-storage-library-proposal-v2.md),
[caller inventory](00-caller-inventory.md) and
[build/result reuse contract](../qualification-build-reuse.md).
Product authority remains the [specification](../../../iCloud-Drive-Support-Spec.md),
[ADRs](../../../adr), [CONTEXT](../../../../CONTEXT.md) and
[model guide](../../../tla/README.md). Physical assumptions come from the
[Apple API ledger](../../../Apple-API-Contract-Validation.md) and
[Foundation contract](../../../Foundation-Safe-Replacement-Migration.md).

Preserve these boundaries:

- Admission, durable acceptance, checked model publication, provider installation
  and peer acceptance are separate observable events.
- Both profiles use the real encrypted private database and current zstd formats.
  Password-free recovery requires no Keychain or separately held secret.
- Missing repository entries use add-only repair. Occupied damage stays at the
  source with Save As available. Verified local bytes take their canonical names
  in a fresh copy; its report identifies damaged source entries preserved in place.
- Work Offline releases only the specified positive-disclosure startup wait.
  Generic provider errors and later disclosure preserve healthy local editing;
  they grant no overwrite, deletion or retargeting authority.
- Complete private repair and verified selection precede provider republishing.
  Required private inputs survive; incomplete copies retain their explicit scope.
- Phase 6 owns plaintext admission/association/deletion and actual pending-file
  completion. Phase 7 owns AppKit, input/undo, resolver UI and app quit/switch.
  P5.7 qualifies their implemented storage boundaries, not those integrations.
- Epoch-4 opening/recovery/export remains the compatibility boundary. Current
  development formats require no superseded-draft migration.

No new storage protocol, persistent test state, permission registry, history cache,
workflow framework or product-policy decision is required to start. A genuine
policy contradiction requires human direction before changing the contract.
Preserve its failing schedule and continue unaffected work.

## 2. Dependency-ordered increments

| Increment | Deliverable | Exit |
| --- | --- | --- |
| A — Evidence baseline | Source-bound reuse inventory and missing-connection map | Every obligation is evidenced or explicitly scheduled |
| B — Harness boundary | Typed scenarios, reached gates, coherent observations and fresh-process readers | Observer/fault/discovery controls fail for the intended reason |
| C — Transport and publication | S1–S3 connected witnesses | Real retention, stale-result handling and automatic progress pass |
| D — Recovery and lifetime | S4/S6, including second failures and switch interference | Sources, required state, selection and entered resources remain accounted for |
| E — Causal replay and bounded exploration | S5, selected three-writer cases, finite orders and replayable generated schedules | Independent semantic results and critical defect controls pass |
| F — Platform/privacy/scaling delta | Uncovered or invalidated capability checks and integrated measurements | Each supported claim has current or justified reused evidence |
| G — Exit report | Seven-gate matrix, limits and Phase 6/7 handoff | No unexplained critical failure, survivor, missing case or stalled valid path |

Complete each increment's valid and fault companions before expanding it. Keep the
debug edit loop narrow; stabilize cases before optimized/platform qualification.
Each scenario owns its mutable stores, allocators and gates.

## 3. Increment A — Reuse completed qualification precisely

Create `07-connected-qualification-validation.md` when execution begins. Start
with an obligation table rather than a green aggregate. Each row records:

- requirement/scenario and actual issuer, caller and consumer;
- production, harness, fixture and oracle input hashes, command and parameters;
- binary, dependency, compiler/language, SDK/deployment, OS and architecture;
- fault class, reached cut, raw evidence, verdict and reuse rationale.

Use complete relevant file-content inventories for this dirty worktree; a commit
ID alone cannot identify the tested code. Preserve first failures and incomplete
runs separately from successful reruns.

### Evidence inventory

| Existing report | Reusable claim | P5.7 addition / invalidation trigger |
| --- | --- | --- |
| [P5.1](01-root-ownership-validation.md) | Directory exclusion, movement, held lane, detach/remount and cleanup | S6 joins these to acceptance, close and fresh recovery; changed owner/executor/FFI paths require reruns |
| [P5.2](02-immutable-files-validation.md) | Immutable installation, equal-final barriers, process cuts and permitted-loss observer | S1/S4 connect surviving names to acceptance/repair; changed installer/barriers/loss rules invalidate that slice |
| [P5.3](03-local-repository-exchange-validation.md), [batching](bounded-discovery-batches-validation.md), [connection reuse](private-connection-reuse.md) | Nested discovery/receive, transport, accepted hints and bounded native/SQL work | S1/S2 add combined failures and stopped notifications; changed queue/cursor/hint/connection consumers require checks |
| [P5.4](04-apple-coordination-and-discovery-validation.md) | Scoped accessors, stage/presenter lifetime and signed two-Mac exchange | S6 and changed adapters need actual entered-accessor witnesses; provider observations keep their exact stimulus scope |
| [P5.5](05-startup-and-root-reassociation-validation.md) | Startup, named waits, Work Offline, Retry/Re-open and signed reassociation | S3/S6 connect optional work, interrupted receive and later root events; request-only evidence cannot qualify P5.6 effects |
| [P5.6](06-repair-replacement-and-copy-validation.md) | Add-only repair, private union/activation, copy/switch, bounded S4, signed repair/copy/Undo, Intel and Linux checks | Extend missing S4/S6 combinations; preserve its two-Mac witness, 62-case Linux slice and compiler/process results at their recorded revisions |
| [Phase 3 matrix](../phase3-schedule-observation-matrix.md) and implementation reports | Deletion, restoration, conflict copies and compensation semantics | S5 carries those histories through actual roots, backups and a third writer |
| [Phase 4 improvements](../phase-4-improvements/validation.md), [startup/scoped queries](../phase-4-improvements/startup-and-scoped-queries-validation.md), [retention](../phase-4-improvements/snapshot-retention-coverage-validation.md) | Verification replay, recovery, scoped reads and required/optional work | S3 connects transport; snapshot-retention and represented-operation ancestry remain distinct |

### Reuse rules

1. **Build reuse:** retain warm SwiftPM outputs and existing native build receipts.
   Bind transitive inputs, configuration, actual compiler/SDK and library bytes.
   Reusing an executable still executes each newly selected scenario.
2. **Exact result reuse:** use `qualification_reuse.py` and the existing campaign's
   verified records for their declared independent checks. Label reuse and link its
   producer/log. Failure, timeout, corrupt/missing evidence or changed inputs
   requires real execution, never a reconstructed success record.
3. **Earlier component evidence:** retain an unchanged responsibility's result only
   with a reviewed input-diff/impact rationale. This is narrower than claiming the
   entire current binary was run. Inadequate provenance requires the affected
   component rerun, not an assumed equivalence.
4. **Environment:** a new OS/toolchain/signing/adapter configuration needs affected
   executable qualification. Linux success cannot certify Foundation behavior.
5. **Models:** unchanged model/config/runner results retain their original scope.
   New executable cases alone do not mandate unrelated TLC reruns.
6. **Setup fixtures:** reuse checked, closed history setup under the existing
   [fixture rules](../shared-history-fixture-pilot.md); clone into independently
   owned mutable stores. Fixture setup differs from an explicit old-backup test.

Keep compiler-probe batching, cohesive test modules and the mutation cross-product.
Do not add arbitrary runtime/live-provider success caching. Changed oracles, fault
seams or assertions invalidate their affected results. Avoid concurrent heavy
compiler campaigns on resource-limited hosts.

**A exit:** all required rows are either justified reuse or explicit new work;
planned, failed, unsupported and inconclusive remain distinct.

## 4. Increment B — Small, honest connected harness

Extend existing machinery:

- Add native connected cases beside Runtime tests, assigned exactly once to the
  appropriate cohesive target in `Package.swift`. Prefer a small
  `Phase5ConnectedTests.swift` with module-private helpers; preserve target
  membership and test-only dependency-boundary checks.
- Reuse `NVStorageProbe`, `CollectionControllerProbe`,
  `RepositoryDriverProbe`, `StorageWork`, C fault controls and the independent
  history inspector. Add commands only for missing actual operations/observations.
  Preserve existing entrypoints and every registered case.
- `tools/test-storage-phase5-connected.py` drives connected S1/S5 and generated
  child-process schedules using existing probe binaries. Its listing, exact
  family/case selection and observer self-tests are implemented. `--replay`
  repeats a logical case manifest; `--replay-wire` reuses generated schedules'
  exact envelopes, seed store and failure cuts. S2/S3 and live S6 interleavings
  use the Swift consumers; S4 reuses and extends the existing repair/copy drivers.
- Use closed Swift enums and immutable values for test steps/faults. Distinguish
  command intent, effect entry, effect completion, callback and observation.
  JSON controller messages remain untrusted instructions/results, never constructors
  for production permissions or acceptance evidence.
- Control repository visibility/completion below real consumers. Each modeled host
  owns separate roots/private stores. Live iCloud separately qualifies the real
  provider; deterministic local delivery is not evidence of actual cloud ordering.

### Coherent independent observations

Inspect exact bytes and SQL membership independently of success flags. Capture
current rows/context at one checked prefix or settle the actual owners before
comparing several semantic queries. Accepted history may lead current materialization;
separately sampled prefixes need not match during background receive.

During live polling, check the narrow promised fact, such as exact retained bytes
and accepted membership. After explicit settlement, run the full independent
history/value oracle. Check stale completions, pending generations and local
progress **before** closing; quiescence must not hide those races.

A freshly exec'ed recovery client receives only surviving storage, normal
selection/unlock inputs and specified choices. Expected notes and the parent's
command/acknowledgment log stay with the observer. Use literal difficult-history
expectations and a small set-based reference for outputs beyond the independent
Node inspector's implemented scope. Production fast/full agreement supplements
them; production reducers cannot supply the sole expected answer.

Use reached entry/return handshakes. A held-accessor test fails if its backstop
release enabled the supposedly independent save. A switch-success case waits for
actual receive settlement; a companion deliberately holds receive, requires exact
safe refusal/unchanged selection, then releases it and succeeds. Preserve P5.6's
strengthened competing-copy test. Sleeps or a chosen number of `Task.yield()`
calls establish neither state. Watchdogs terminate tests, not prove correctness.

| ID | Independent observer/controller defect | Required detection |
| --- | --- | --- |
| P57-H1 | Omitted selected case/parameter or unreached gate | Missing discovery/reachability; zero tests cannot pass |
| P57-H2 | Alter one expected byte, member, birth, disposition or private-input digest | Corresponding independent assertion fails |
| P57-H3 | No-op injector, wrong occurrence or exit before cut | Missing effect proof; ordinary success cannot count as crash coverage |
| P57-H4 | Mix accepted/view observations or trust copy success alone | Reject incoherent report; require exact copy/readback evidence |
| P57-H5 | Ignore installed final after lost callback; always-durable loss observer | Recovery or persistence-prerequisite assertion fails |
| P57-H6 | Reject all valid input or never resume useful work | Named valid/progress obligation fails with the blocked event chain |

**B exit:** valid and defective observer companions behave as intended; tests obtain
evidence through real issuers without public constructors or acceptance shortcuts.

## 5. Increments C–E — Connected scenarios

Every row runs in both profiles with independent bytes/membership/private-state
observations, a successful companion, reached cuts and fresh final recovery where
specified. Each S-family must execute its difficult sequence in one connected run;
disconnected unit results do not establish that connection.

### C: transport, live state and startup (S1–S3)

| ID | Concrete schedule and variants | Required result / challenged guard |
| --- | --- | --- |
| P57-01 / S1 | A saves E; B receives before two prerequisites, parks and crashes; prerequisite acceptance races restarted parking/settlement | Exact bytes/waits survive; both prerequisites required; atomic wakeups prevent stranding; unrelated work progresses |
| P57-02 / S1 | E accepts; hold prepared publication; B admits F as edit or Delete, including equal body/different represented inputs | E stays historical; stale update neither invokes host nor clears F; recomputation after finite interference needs no new delivery |
| P57-03 / S1 | F commits without callback; fail current-row recovery once; healthy exec/open and bidirectional delivery | Complete E/F closure survives; exact retries give one logical effect; expected values/heads/alternatives and untouched note remain |
| P57-04 / S2 | Hint before empty listing; expose new nested writer, high child, low parent and renamed duplicate; stop hints | Production ordinary revisits accept every eligible object once; no high-water filter, lost parent/EOF tail or one-pass completeness |
| P57-05 / S2 | Partial batch handoff, restart, failed read/hint write and changed accepted-file observation | Durable handoffs survive; remaining entries recur; exact unchanged hints skip reads, changed evidence takes checked path; healthy retry resumes neighbors |
| P57-06 / S3 | Optional roots/pages queued before required Changes; hold optional work through actual CollectionSession publication | Complete required work precedes editing; optional work does not gate it; later snapshot acceptance changes no note |
| P57-07 / S3 | Two finite saves interrupt background validation; release and send no further input; close/reopen and rejection-write-failure variants | Existing notifications resume work; queued bytes survive; explicit I/O retry differs from contention resumption |
| P57-08 / S3 | Healthy-return companions: required snapshot bootstrap/rebuild, unfinished verification, known damage; initial named unread versus late/generic disclosure | Required evidence still gates editing; Work Offline stays scoped; later disclosure never revokes healthy editing; failed host callback starts no successful-publication handoff |

Reuse `RepositoryTransportTests`, `RepositoryExchangeTests`,
`OptionalStartupTests`, resumption/rejection tests and P5.5 consumers. Add missing
cross-boundary schedules. In P57-02/03, still-RAM F has live ownership guarantees;
only its committed branch promises crash recovery.

### D: repair, selection and resource lifetime (S4/S6)

| ID | Concrete schedule and variants | Required result / challenged guard |
| --- | --- | --- |
| P57-09 / S4 | Known closure split across private/provider/backup, with unpublished history, settings, latest/frozen pending inputs, rejected/parked input and verification | Real acquisition forms exact compatible union; private groups/provenance survive; evidence missing everywhere prevents complete activation |
| P57-10 / S4 | Fail before/after private acceptance, verified reopen or selected-record install; fail diagnosis/verification/readback again in recovery | Old or complete new committed evidence; both candidates and obligations recoverable; opener follows actual selection, not callback assumptions |
| P57-11 / S4 | After private activation race compatible/foreign names against missing-entry repair; occupied corrupt file/directory companions | Add-only collisions preserve contenders and local editing; occupied damage offers Save As; complete private union precedes republishing |
| P57-12 / S4 | Copy history/extras with damaged canonical source; source changes during preparation; retry switch | Verified canonical destination bytes and preserved/reported source damage; changed source stays selected; quiet retry opens exact history/private inputs with fresh ownership |
| P57-13 / S4+S6 | Optional accepted-name checking/receive during copy; held accessor; cancellation/close around uncertain selection | Reservation defers optional work but admitted writes still invalidate preparation; uncertain selection retains resources/restart inputs until settlement |
| P57-14 / S6 | Enter/hold accessor; save E locally; cancel/timeout; move root or recreate old path with equal collection bytes; release late | E's barrier precedes release; old work cannot authorize replacement; one completion and safe lock/handle lifetime |
| P57-15 / S6 | Close/Retry/explicit Re-open with held work, rejection-write failure and second restart; healthy retry | Old typed evidence fails at new consumers; independent contention checks exclusion; exact input/blocked descendants survive and valid neighbors resume |

Extend the existing repository repair/copy/private process drivers and
CollectionSession switch/reassociation tests where they already own the operation.
The connected controller may compose them; recovery must not receive hidden source
copies or saved capabilities. Account for unavailable repository extras separately
from exact history required by an editable destination.

### E: causal replay and three writers (S5)

| ID | Concrete schedule and variants | Required result / challenged guard |
| --- | --- | --- |
| P57-16 / S5 | Restore B's older backup while A retains Delete; restart both; redeliver old/repackaged ancestors; B independently edits old birth | Fresh session epochs/origins; older view permitted before undisclosed Delete; after complete delivery old birth absent and concurrent content preserved by existing rules |
| P57-17 / S5 | Fresh-birth Restore/edit meets old Delete in both orders; third writer adds descendant or independent branch | Old Delete cannot erase fresh birth; exact identities, contents, alternatives and Recently Deleted match literal history, not arrival order |
| P57-18 / S5 | Reciprocal representation-only copies, copy deletion and new source descendant; causal Undo/Redo or reviewed compensation with unrelated work | Copy does not select/delete source; completed dispositions survive copy deletion; new descendant stays reviewable; actual compensation candidates and unrelated values survive reopen |

Use existing APIs and Phase 3 vectors. Freeze the same command/history fixture
before permuting delivery: commands authored against different observed frontiers
are different scenarios with different expectations. Collection/bulk action groups
remain complete. Actual AppKit undo is outside this gate.

### Bounded exploration

After curated witnesses detect their mutations:

- Start with two writers, one/two notes, two/three additional complete actions,
  one optional snapshot, zero/one/two failures. Enumerate applicable delivery and
  completion orders of each reviewed small history skeleton. Third-writer cases
  are required for P57-17/18, not every cross-product dimension.
- Sweep single faults across reachable boundaries first; then pairs whose second
  fault occurs in actual recovery/settlement. EIO/ENOSPC, lost callbacks, namespace
  changes and cancellation appear only where their primitive permits them.
  Never split an atomic commit/rename into impossible intermediate effects.
- Print the full selected case/parameter/cut manifest before running; verify
  completion and reachability afterward. Exhaustiveness refers only to that finite
  manifest. Budget exhaustion remains incomplete; never silently truncate coverage.
- Extend existing generated/replay machinery with repository schedules. Begin
  with seeds 0–3, then extended 0–15, at most eight additional actions, three writers
  and two failures per run. Save full schedules, actual allocated IDs and environment
  choices; a seed alone does not control Swift scheduling or random allocation.
- Metamorphic companions vary duplicate/renamed delivery, equivalent operation
  packaging, restart, safe movement and resumable work budgets. Compare at a
  comparable settled history; temporary Current need not agree.
- Minimize failures while preserving input validity, reached boundary and the same
  failed predicate. Keep original/reduced traces. An earlier parser rejection
  cannot replace the original semantic counterexample.

**C–E exit:** all selected valid companions complete; independent assertions and
reached cuts support every claim. Deferral has its explicit retry/progress witness.

## 6. Compiler boundaries and mutation qualification

Retain Swift 6.4+, Swift 6 mode, strict concurrency/memory diagnostics and actual
production optimization/exclusivity settings. Preserve conditional C/Objective-C
boundaries. No Linux weakening, test-access widening, global unchecked Sendable
or provider blocking on the cooperative executor. Existing actors reserve work
before suspension; consumers recheck context afterward.

| Boundary | Compiler check | Dynamic counterpart |
| --- | --- | --- |
| Root permission/observation/turn/install evidence | Ordinary and same-module clients cannot construct/mutate issuer facts or substitute raw paths | P57-05/14/15: wrong root, generation and closed session, even with equal logical identity |
| Capture, acceptance and prepared publication | Distinct roles and restricted issuers remain | P57-01–03: changed live generation, exact coverage or prefix, including equal body |
| Captured history, checked repair, verified replacement and selection | Requests/copy reports cannot construct completed repair or activation | P57-09–13: exact union/source/candidate/selection; no old local-sequence transplantation |
| Native handles/stages | Non-Sendable resources stay confined; existing unique stage transfer remains enforced | Hold/cancel/timeout lifetime, cleanup and independent exclusion observations |
| Controller/test support | No production test dependency or decoded/raw capability constructor | Ordinary clients obtain real evidence; malformed authenticated fixtures use isolated test writers |

Run existing Core/runtime/private/root probes where the touched boundary lives.
Keep valid companions, marked diagnostic locations, compatible batching and isolated
same-file/source-modifying checks. New evidence types require ordinary and
same-module challenges. Prefer existing narrow values/closed enums over generic
typestate plumbing.

Map the testing plan's complete [defect table](../phase5-provider-root-testing-plan.md#targeted-defects)
to reused qualified mutations or new witnesses. Prioritize:

- missing dependency wakeup / clearing newer work (P57-01–03);
- early cursor/dirty completion / stale accepted hint (P57-04/05);
- early publication / lost wakeup / skipped verification (P57-06–08);
- dropped private group / incomplete union / unsafe activation / occupied overwrite
  (P57-09–12);
- omitted source/receive fence / selection readback / accessor settlement (P57-13–15);
- allocator reuse / arrival-ordered Delete / lost disposition / wrong compensation
  target (P57-16–18).

Keep the existing mutation cross-product. Every runtime kill requires its passing
baseline, discovered parameters, reached consumer and intended assertion.
Compile-blocked is static evidence; setup errors, timeouts and unrelated failures
are separate. Investigate survivors without removing redundant real safeguards.
No retry-until-green or weakened assertion may substitute for diagnosis.

## 7. Increment F — Platform, privacy and scaling delta

| ID | Workload | Strict observations; separate measurements |
| --- | --- | --- |
| P57-19 | Two fixed current notes, 64/256/1,024 ordinary actions; returning open with transport/optional work queued | Existing indexed/current-row bounds; no mandatory full-history replay; measure publication, background work and exceptional recovery separately |
| P57-20 | Same-history scans/accepted-name checks; new writer/object, changed fingerprint, sequential and wide snapshot tips | Preserve native/SQL batch and unchanged-body-read assertions; report catalog/history/frontier growth independently; lowered budgets preserve eventual results |
| P57-21 | Backlogged transport/held accessor during save; repeated cancellation/close/reopen/copy | Local barrier before release; bounded in-flight work and buffers; descriptor baselines after actual settlement; record latency/peak memory |
| P57-22 | Body/title/password/path/bookmark markers in malformed input, wrong-key, stage/error/repair/copy/export/restart paths | Inspect actual production sinks; encrypted confidentiality separate from password-free recovery; label explicit exports and test-oracle fixtures |

Reuse current growth sizes and the checked fixture pilot. Keep exact existing
work-count assertions, including qualified per-execution SQL alternatives.
A benchmark supplies no authority to truncate history, introduce a lifetime cap,
skip validation, restore a packed cache or defer live search. Report construction
cost, warm/cold regime and per-phase measurements; establish any new threshold
from measurements rather than invent a universal latency promise.

### Platform matrix

| Target | Current/reused evidence and new delta |
| --- | --- |
| Current arm64 macOS | Connected debug/optimized suites, process cuts, affected native diagnostics and ASan/TSan with controls |
| Intel macOS 14 | Portable connected subset and changed Foundation/root consumers; signed peer role and fresh exact-byte reconstruction |
| Intel macOS 11 VM | Compatible standalone probe executes affected library/FFI paths; record actual 11.7.x versus declared 11.5 floor and compiler/runtime workaround, separately from distribution |
| Ubuntu arm64 / Multipass | Same portable contracts, affected debug/optimized/process/compiler checks and actual executable ELF protection; permission tests run non-root |
| APFS/APFSX, HFS+/HFSX, ExFAT | Reuse unchanged per-operation evidence; affected paths get image ENOSPC/detach/remount; retain ExFAT exclusive-install and fresh deep-HFS+ limitations |
| Signed two-Mac iCloud | Reuse P5.4–P5.6 within revision/stimulus scope; add uncovered connected histories or changed consumers; exact receiver reads and fresh reconstruction |

### P57-23 — Signed-provider qualification delta

Select uncovered S1/S5 or S4/S6 compositions
after the reuse audit. Account for both profiles and send directions across the
evidence set. SSH may transfer harness/source/normal unlock inputs; history under
test travels through the provider. Eviction/materialization and remote movement
count only when independently observed in owned fixtures. Unachieved dataless-root
or remote-origin stimuli remain inconclusive; safe unknown/unavailable behavior
still gets executable companions. No upload/silence/reverse-lookup/portable Apple
ID assumptions. Check correct API use before claiming a contract violation.

### P57-24 — Persistence/lifetime qualification delta

Keep process termination, existing
permitted-loss images, later corruption and volume/VM restart separate. A reached
process kill does not prove hardware power loss. Qualify actual sanitizer/loss
observer instrumentation with deliberate controls; Runtime ASan alone is not
instrumented SQLCipher evidence. Production signing, final macOS 11 packaging,
physical power loss and application integration retain later gates.

Use authorized synthetic repository trees and owned images; preserve failures and
respect per-host cleanup permissions. Ubuntu is Multipass-managed, not UTM.
No account resets, sign-outs or real-provider quota filling. An unavailable host
or unsupported sanitizer is not a passing run.

## 8. Models, execution tiers and exit

### Model correspondence

| Family | Existing checks | Concrete obligation |
| --- | --- | --- |
| S1 | Immutable durability, SQLite collection, receive resumption/rejection | Actual bytes, complete membership/wakeups, commit-versus-callback and pending generations |
| S2 | Repository discovery, metadata batches and accessor driver | OS catalog/partial handoff, hints and actual worker opportunities |
| S3 | SQLite fast start, optional startup, collection startup/association, snapshot assembly/reconstruction | Real required selection, coherent host publication and positive disclosed evidence |
| S4 | Repository repair/copy/switch and verification replay | Exact union/private inputs, contenders, selection barriers/readback and ownership |
| S5 | Segment merge/deletion/action, conflict-copy and causal compensation | Encoded histories and independent semantic results after physical transport/reopen |
| S6 | Local durability lane independence, accessor driver, startup/association | Entered accessors, independent barrier, exact replies and disposal |

Use exact modules/configurations from the [model guide](../../../tla/README.md).
Separate passes do not automatically compose into a program proof. Classify
counterexamples as harness error, implementation defect or genuine policy issue
against the written rules. Preserve safety properties. Update/run only affected
model/config/correspondence when modeled behavior changes, including designated
negative and reachability/progress controls. Add a focused model only for a
critical uncovered interaction. Finite exhaustive checks, sampled schedules and
implementation witnesses retain distinct claims. No generic translator,
whole-program refinement or wall-time ordering of independent host logs is required.

### Commands and efficient execution

Existing entrypoints:

```sh
# Connected production paths; every listed parameter remains required.
python3 tools/test-storage-phase5-connected.py --self-test
python3 tools/test-storage-phase5-connected.py --list
python3 tools/test-storage-phase5-connected.py --binary NVStorage/.build/debug/NVStorageProbe
python3 tools/test-storage-phase5-connected.py --binary NVStorage/.build/release/NVStorageProbe --family generated --seeds 16
python3 tools/test-storage-phase5-connected.py --binary NVStorage/.build/release/NVStorageProbe --replay-wire /absolute/campaign/case/wire-schedule.json
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter phase5'
python3 tools/test-storage-runtime-mutations.py --only p57-clear-newer-pending --only p57-publish-stale-generation --only p57-abandon-interrupted-validation --only p57-drop-prefix-followup --jobs 2 --timeout 1200

# Focused loop; select actual declared tests from the case manifest.
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter repositoryDriverRevisitsEmptyPassAndLatePrerequisite'

# Full local qualification when the affected-input audit requires it.
python3 tools/test-storage-phase2.py --configuration both --reuse-directory /absolute/owned/campaign/reuse

# Observer and documentation gates.
python3 tools/test-qualification-reuse.py
python3 tools/test-storage-apple-repair.py --self-test
python3 tools/test-storage-apple-transport.py --self-test
python3 tools/generate-test-index.py --self-test
python3 tools/generate-test-index.py --write
python3 tools/generate-test-index.py --check
```

Use part ledgers for exact existing process/compiler/mutation/signed commands.
New runner commands enter this plan/index when implemented, with discovery checks.
Current source membership determines required tests; an old count is provenance.
Reuse probes only against unchanged recorded inputs; serialize relinking against
child launches. Source/fixture changes during qualification invalidate affected
results rather than attributing mixed runs to one revision.

| Tier | Work |
| --- | --- |
| Edit/increment | Affected debug cases, observer controls, narrow compiler/mutation checks and warm builds |
| Stabilized connected campaign | All new S1–S6 cases in debug/optimized builds, finite manifests, second failures, generated/replay and affected mutations |
| Final evidence set | Reused component results plus uncovered/invalidated platform, fixture/schema, privacy, resource, sanitizer and native/legacy checks |

Run full debug/optimized inventories only as needed after source stabilization;
later documentation-only edits do not warrant repeats. App build/integration and
epoch-4 compatibility rerun if their inputs changed or matching evidence is absent.
Planning alone requires neither a storage build nor TLC execution.

### Final report and handoff

The ledger maps all seven [Phase 5 exit gates](../phase5-provider-root-testing-plan.md#11-reporting-and-completion-gates)
to current/reused evidence. For each P57 row record counts, reached cuts, valid and
invalid companions, assertions, mutation verdicts, source/binary identity and
artifacts. Explain omitted/inconclusive work and approved capability limits.
Unexplained critical survivors, stale results, undiscovered cases or permanently
stalled valid work block that gate.

Update the overall plan, caller inventory, Swift roadmap and validation index.
Link corrective source changes to their requalification; preserve earlier failures.

Phase 6 receives qualified rooted reads/listing/exclusive installation, scoped
coordination, transport, health/repair and copy/switch with their capability limits.
It still implements actual external-file decisions, expected-generation projection
replacement/removal and pending completion. Phase 7 still supplies human-reviewed
AppKit/input/quit integration and Apple-member disposition. Phase 8 retains
distribution/security/power-loss gates. P5.7 completion establishes the seven
Phase 5 gates within those boundaries, not universal provider convergence or a
finished application.
