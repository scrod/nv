# Swift storage conformance and failure-testing strategy

**Version:** 1 — proposed companion to `swift-storage-library-proposal-v2.md`  
**Date:** 2026-09-10  
**Status:** actionable test design and implementation backlog; not an executed conformance report.  
**Scope:** proposal-5 semantics implemented through the proposed cross-platform Swift core and its application/platform adapters.

Aligned with the current specification on 2026-09-10. The [phased implementation/testing plan](swift-storage-implementation-plan.md) sequences these contract cards against the actual repository, using direct Swift canonical definitions without CUE/code generation. This document supplies detailed testing rationale and scenarios, not an executed report or alternate product policy.

Implementation includes the [first-save contract](first-save-reopen-contract.md),
Core codecs and bootstrap/ordinary validation, and the [Phase 2 local Runtime](phase2-local-runtime-validation.md).
The [Phase 3 connected report](phase3-validation.md) adds editable derived Current,
conflict/deletion/recovery commands and portable compensation through independent
stores. These reports distinguish issuer, consumer, intent, process and mutation
evidence for their supported subsets. Whole-storage/application gates below remain
open. The first bootstrap includes its initial snapshot. The
[Phase 4 S3/S4 report](phase4-bootstrap-reconstruction-validation.md) adds complete
store-backed bootstrap and verified snapshot-plus-history reconstruction, following
the separately qualified general snapshot codecs and acceptance. Private packing
is removed. The [4C–4E report](phase4-private-state-repair-copy-validation.md)
adds actual private-record/reference transactions, fixed-cut backup, complementary
repair, physical local selection and copy/export consumers with their failure and
language-boundary checks. Provider/UI adapters retain their later gates.

## Executive decision

Build a **small production-path conformance harness**, beginning with one complete local-save/reopen slice. Use v2's type boundaries to identify the issuers and consumers to challenge, not as substitutes for those challenges. Expand to two-store histories, application integration, and actual filesystem/provider qualification only as the relevant production paths exist.

For each critical obligation, require four things: a valid case that succeeds, a near-valid case that must not obtain authority, independently specified observable outcomes, and a plausible implementation mutation that the test demonstrably detects. Add actual OS evidence where a claim depends on an OS primitive.

The first deliverable is not a generic simulator or a generated specification. It is real capture → canonical encoding → sealing → immutable installation → retained-pin commit → completion → fresh reopen, with controlled failures below the installer and independent checks above it. Both profiles must eventually exercise the same path; passing a public-suite prototype does not qualify encrypted storage.

This plan changes **verification organization**, not the wire protocol or product semantics. It uses the adopted private SQLite database and its engine-owned journal; it does not introduce another application WAL/database, receipt registry, global synchronization barrier, history pruning, co-add, or permission to weaken a platform adapter. All scenario IDs and work-package names below are proposed test artifacts, not existing implementation symbols. [P1–P6]

### How to use this document

Read §§1–6 to establish the test boundary and oracles. Implement the G0/G1 work packages in §13. The contract cards in §§7–8 provide concrete schedules and assertions; §9 carries the remaining feature-specific backlog. Apply the mutation and evidence rules in §§10–12 to every enabled feature. Appendix A summarizes conformance obligations for v2, and Appendix B links the strategy back to the adopted requirements.

## 1. Authority, source basis, and explicit gaps

The adopted specification, Protocol/Encryption annexes, ADRs, and CONTEXT remain the authorities. V2 is a proposed implementation architecture. This strategy selects test organization, test IDs, observation seams, challenge cases, and release evidence; those selections are recommendations rather than newly discovered product requirements. [P1–P6]

The supplied verification material already requires real bytes, independent expected-note oracles, fault hooks, fresh-process recovery, and specific integration scenarios. It also records bounded model/reference results while identifying their abstraction limits. This strategy turns that material into executable work rather than treating it as absent. [P3, P5]

**Not established by this strategy alone:** whole-engine conformance or completion of the gates below. The first-save contract and Phase 2 report separately record working Core/Runtime subsets and concrete checks; those results do not turn the rest of this backlog green. V2's nine isolated compiler probes remain historical evidence for language patterns only, not tests of the package.

The actual [test driver](../../../tests/Makefile), [test guide](../../IntegrationTests.md), [history reference checks](../check-history-rules.py), [active models](../../tla/README.md), [Apple API contracts](../../Apple-API-Contract-Validation.md) and [safe-replacement contract](../../Foundation-Safe-Replacement-Migration.md) are present in this repository. WP0 inventories/reuses them and records revisions; it does not retrieve or recreate an external source bundle. Existence alone is not an executed result. The [Phase 2 report](phase2-local-runtime-validation.md) records the implemented local Runtime subset, independent observers, controlled SQL/VFS completions, construction probes and targeted mutants. It does not certify the entire engine or every contract card below.

**Test organization:** retain the existing Makefile driver and legacy integration executables, and invoke the package's native Swift tests for new code; portable jobs use the package directly without the Cocoa app. This is the current implementation direction, not a pending policy choice. Qualify the test runner separately from the macOS 11.5 library/bridge executable, using compatible standalone probes when necessary. No third-party/duplicate framework or duplicated suite. [P3, P6]

## 2. Where v2 is useful—and where it needs stronger evidence

V2 usually acknowledges the limitations below. Its weakness is principally that acknowledging a limitation does not specify the test that discharges it.

| V2 concept | Retain and exploit it | Gap this strategy closes | Concrete addition |
|---|---|---|---|
| §§2, 4, 6: nominal types and restricted construction | Identify forbidden calls and the small set of issuers | A wrong value of the correct type compiles | Separate-client compile failures plus compatible-type/incompatible-context tests |
| §§7, 11: one store-owned acceptance commit | Put one low-level fault seam beneath all acceptance callers | The issuer can skip a barrier, omit a dependency, or combine unrelated receipts | An independently checked acceptance predicate; caller sweep across local authoring, receive, reopen, and repair |
| §15: immutable Objective-C snapshots | Freeze intent before worker transfer | The implementation can preserve the wrong capture perfectly | An admitted-command oracle and tests of the real command-to-capture adapter |
| §5: direct Swift definitions and shared canonical traversal | Reduce encoder/hash/size drift without a schema generator | All three consumers can omit the same field | Literal preimages, independently calculated fixture sizes, and field-participation mutations |
| §6: contextual graph facts | Centralize frontier and compensation derivation | Correct antichain but omitted maximum; correct fact for a different history | Writer-context and receiver-context contrast pairs; stale-context injection |
| §10: exhaustive limit fixtures | Force maintenance when a limit is added | Registered fixtures can reject at the wrong layer or miss actual enforcement | Guard reachability, minimally invalid inputs, forbidden-effect checks, guard-removal challenges |
| §12: actors and explicit in-flight phases | Keep ownership and event handling legible | Pure simulations can miss actual actor/queue wiring; synchronous callouts can reenter the bridge | Controlled completions through real adapters; reentrant observer and lane-isolation tests |
| §13: noncopyable resources | Prevent accidental resource duplication | Dropped work and duplicate logical requests remain possible | Cancellation/lifetime tests and idempotence checks across separately allocated tickets |
| §17: deterministic simulation | Reuse production decisions and codecs | An optimistic disk model or self-reporting oracle can certify bad code | A versioned persistence model, observed low-level operations, and harness negative controls |
| §17: model connections | Reuse independently expected histories | A projection can erase the illegal transition; a broken-model trace can be misread as a script of required internal actions | Preserve critical observations; replay environment schedules, not illegal model transitions |
| §§14–15: closed diagnostics and narrow FFI | Restrict disclosure and conversions | Error paths, mutable buffers, and test instrumentation may still leak or change data | Synthetic secret markers, actual sink inspection, and buffer-alias/lifetime tests |
| §18: delivery sequence | Retain dependency and qualification gates | Completing the entire semantic kernel before testing local acceptance delays the most valuable feedback | Interleave a minimal semantic subset with the first real installer/reopen slice |

The engineering target is **truthful issuance + correct use + preservation of intent**, not the number of evidence types.

## 3. Test the obligations, not just their names

### 3.1 Three related contract checks

For every important type that certifies something, ask:

**Issuance:** did the production issuer establish the required facts for these exact bytes, objects, and context?

**Use:** did the consumer require those facts and revalidate any facts that can cease to apply?

**Intent:** did the upstream capture faithfully represent the admitted command, including unchanged fields, before-states, scope, and required pending ancestry?

A receipt test that begins with a test-created receipt exercises use only. A validator test that bypasses the production command adapter does not establish intent preservation. Record this distinction in each case.

### 3.2 Acceptance predicate and independent observation

For a batch H accepted in one private-store incarnation, the test should establish, at the acceptance boundary:

```text
completeAndSemanticallyValid(H)
AND requiredObjects(H) are covered by the committed retained pin
AND every object in that required closure is exactly verified and durably reachable
AND all object/closure/pin evidence describes the same collection and store incarnation
AND the local owner is permitted to commit in that incarnation
```

Here `requiredObjects` includes required descriptors and referenced action/state evidence, not only note-operation parents. The pin stores a maximal segment frontier plus required descriptors; compare its expanded closure, not list equality or a largest sequence number. A correct later pin may cover an earlier object transitively. Installed but parked/unaccepted extras do not all have to be in that pin. [P1, P3]

Do **not** impose this predicate on ordinary local edit admission: admitted text is live before durability. It governs durable acknowledgment and incoming-history acceptance. Likewise, do not require a captured local edit to still be Current before retaining it; a newer pending edit does not invalidate its historical persistence obligation.

Use four observation channels, each with a different role:

| Channel | Records | Must not be treated as |
|---|---|---|
| External command/completion observer | Synthetic commands, committed inputs, generation tokens, emitted acknowledgments and publication notifications | A production WAL, or a log required by recovery |
| Low-level effect journal | Which bytes/handle incarnation/range/name were written or synchronized; actual effect completion versus callback delivery | A success flag copied from the issuer under test |
| Independent fixture inspector/reference | Exact expected preimages, action membership, required closure, small-history values/candidates | Another call to the production reducer |
| Fresh production opener | What the real receiver/recovery path can reconstruct from surviving bytes | An oracle for its own correctness |

The recovery process receives **only** the surviving test store, selected repository/key inputs, and normal startup choices. It must not receive the harness's command log, acknowledgment list, expected graph, or a previously issued capability.

### 3.3 What survival means

An acknowledged saved edit must remain in recoverable retained history with its complete action group and required ancestry. It need not remain Current after a later valid edit or Delete. A complete valid final object that survived installation without a callback must be rediscovered; where its required closure is available, recovery incorporates it and advances the pin before editable acceptance. An unsynchronized unacknowledged object may or may not survive under the selected persistence model. [P1, P3]

Keep three fault classes separate:

| Fault class | Expected scope |
|---|---|
| Application termination | Forget process state and callbacks; reopen the real filesystem's visible surviving state |
| Simulated persistence loss | Select a surviving image allowed by the explicitly stated write/barrier/namespace model |
| Later corruption or deletion of accepted data | Detect missing/corrupt pinned evidence, preserve what remains, and repair/refuse as specified—not a claim that arbitrary media damage preserves data |

Total loss of Local State can also erase the independent pin proving what was once accepted. Do not write a test demanding detection of an undisclosed erased leaf in that situation. Test explicit reassociation and reconstruction of the available closure without a false completeness claim. [P1, P3]

## 4. Harness architecture: reuse production paths at the right depth

### 4.1 Minimal organization

Adapt this conceptual organization to the existing repository instead of creating another framework:

```text
Existing test driver
    Swift contract/unit tests or standalone executables
    Production-path scenario tests
    Fresh-process crash driver + child executable
    Existing model/reference/legacy test commands

Test support, unavailable to production clients
    named completion gates and low-level fault plan
    small versioned filesystem model
    fixture loader + independent inspectors/oracles
    trace/result writer + focused mutation runner
```

Use v2's `NVStorageCore`, `NVStorageRuntime`, and `NVStorageApple` boundaries as the initial ownership map. These are proposed target names; resolve real symbols in WP0. Do not replace a production responsibility with its expected result.

### 4.2 Production versus controlled components

| Under test | Remains production | Controlled by the harness |
|---|---|---|
| Capture | Command adapter, grouping, generation capture, field mapping | User commands and worker-completion timing |
| Byte/identity path | Reader, canonical encoder, hash/AAD assembly, semantic validator | Exact source bytes; fixed test-only allocation/key material where needed |
| Cryptographic composition | Actual selected crypto implementation, domains, nonce plumbing, AEAD invocation | Test vectors and narrowly isolated deterministic test inputs; no production nonce override |
| Local acceptance | Installer algorithm, dependency resolution, private-state updater, acceptance issuer | Individual low-level I/O outcomes and completion delivery |
| Recovery/repair | Real opener, classifier, closure calculation, repair planner and installer | Surviving image, source availability, collision/permission evidence |
| Async ownership | Real actor/queue adapter and its production completion handlers | Named gates at external effects, command arrival, lifecycle changes |
| Provider semantics | Discovery, bounded input reading, ingestion, publication and retry logic | A synthetic repository, disclosed metadata and delivery/removal schedules |
| OS qualification | Actual rooted helpers, syscalls, coordination, credentials and signing | Synthetic test trees and explicitly arranged competing processes/events |

A high-level fake `install() -> DurableObjectBytes` cannot qualify an installer. A prevalidated `DependencyClosedSegment` cannot qualify reception. Those fakes are permitted in narrowly labeled consumer unit tests, but not as the sole evidence for the corresponding production path.

### 4.3 Fault and completion vocabulary

Identify an effect with its operation ID, store incarnation, kind, and a stable per-operation occurrence. Hooks should bracket existing effects rather than create new suspension points in protected critical sections.

A fault plan needs only a small initial vocabulary:

| Injection | Use |
|---|---|
| Fail before the effect | ENOSPC/EIO/permission-style outcomes where the adapter contract permits them |
| Partial read/write | Exercise loops, length handling, short progress and zero-progress termination |
| Complete the effect, hold its completion | Lost callback, stale generation, root switch, and concurrent private-state planning |
| Deliver an old or wrong-operation completion | Check routing before state changes |
| Withhold a provider completion | Verify local progress and ownership retention |
| Terminate child at a reached boundary | Actual application-crash recovery |
| Select allowed unsynchronized persistence | Crash-image tests below the real installer |
| Insert a competing namespace change | Exclusive-create collision or expected-current mismatch |
| Fail recovery after a preceding failure | No destructive fallback when repair itself is incomplete |

Do not label arbitrary post-effect failures as real syscall behavior. Distinguish a failed syscall, an ambiguous operation outcome, and a lost/delayed callback. The adapter's documented semantics determine which outcomes are admissible.

Late or duplicate callbacks should enter the production adapter at its event/callback boundary. Do not make a test pass by directly resuming a one-shot Swift continuation twice and counting the resulting harness trap as a detected storage defect.

### 4.4 Named boundaries to instrument first

Proposed observation names are stable test identifiers, not extra production states:

| Boundary | Observe/inject |
|---|---|
| Capture frozen | Exact operation/action inputs before worker transfer |
| Sealed bytes fixed | Retry identity and immutable-byte ownership |
| Private acceptance transaction writes | Exact bytes, complete membership, pin and ready work; inject SQL/VFS failures |
| Private commit completed | Exact committed operation versus lost/ambiguous callback |
| Materialization transaction | Captured accepted prefix/view generation, changed/deleted births, global context |
| Current-row capture/publication | Consistent complete rows/context/prefix; final owner/lifecycle/view-epoch checks; no unbounded-history reread on healthy launch |
| Required private-state transaction | Settings/pending payload/reference/receipt generations and atomic settlement |
| Provider staging/file/name/directory/readback | Real namespace barriers, collision handling and exact bytes; separate from SQLite |
| Acceptance emitted | Independent observer checks all prerequisites |
| Main-thread publication/completion | Final generation/context check; no replay of old body |

After a rename-like installation, simulate/observe an **atomic namespace operation only where the selected primitive actually guarantees it**. Do not split an atomic primitive into impossible states; do not combine several real operations into one optimistic atomic effect.

### 4.5 A small filesystem model, not a second filesystem implementation

The test model needs object/handle identity distinct from path, volatile versus guaranteed durable file contents, directory entries and their durability, exclusive creation, qualified replacement outcomes, and process-owned resources. A file synchronization must not implicitly synchronize every directory or another file. A directory barrier must cover only the namespace facts its contract guarantees.

An unsynchronized write is not automatically lost; the model must permit appropriate surviving outcomes. Conversely, a successful qualified barrier must impose its promised persistence constraint. Keep application-crash mode separate from persistence-loss mode. Inject later corruption explicitly rather than silently violating a successful barrier's assumed guarantee.

Version this model and its assumptions. Check it with tiny examples: synchronized file/unpersisted name; durable directory entry/unpersisted file; nested directory reachability; previous-versus-new projection replacement; opened object moved away from its original path. A mutation that makes every write automatically durable must cause a harness self-test to fail.

For private storage, use the real SQLite engine with VFS/transaction fault injection as specified in [LocalStore](../LocalStore.md), not a simulated private object-file/pin-file installer. Keep this filesystem model for provider/projection effects and database activation/backup boundaries. SQLite atomicity is a storage assumption to qualify, never evidence that NV's reducer or acceptance bookkeeping is correct. FoundationDB likewise combines simulation with real performance and hardware-failure testing. [W1, W2]

## 5. Oracles and fixture discipline

### 5.1 Independent expected results

Use a deliberately small oracle for each responsibility:

| Oracle | Construction | Avoid |
|---|---|---|
| Command meaning | Hand-declared before/after fields, intended scope and action boundaries; real committed input observed at the bridge | Reusing the production command-to-operation builder to derive expectations |
| Canonical bytes | Annotated literal bytes and field participation; fixed primitive vectors | Recreating expected bytes through the production Swift encoder/traversal |
| Small-history semantics | Full recomputation from explicit edges with straightforward sets/iteration; concrete expected IDs/values | Mirroring production incremental caches or importing production candidate helpers |
| Persistence prerequisites | Effect journal plus the selected disk model and independently identified closure | Trusting `isDurable`, `isPinned`, or receipt existence |
| Physical authority | Actual opened-resource identity and captured external changes in OS tests | Assuming a matching collection ID, path or digest means the same directory |
| Outcome classification | Explicit allowed categories and forbidden side effects for the scenario | Merely expecting any error |

Reuse the existing [history reference checks](../check-history-rules.py) and reviewed vectors, including their independent original edit coordinates for expected merge output. Preserve their stated scope; they do not exercise production graph selection, persistence or native undo. [P3]

### 5.2 Fixture package

Each important case should keep its fixture provenance, concrete inputs, expected values/preimages, required boundary, fault schedule, expected effects, and mutation mapping together. Ordinary Swift functions and a small amount of JSON/Markdown are sufficient. This is not a new schema-language project.

Store bytes explicitly and large integers losslessly. Freeze operation nonces and keys only in synthetic fixtures. Expected semantic IDs should come from checked preimages; transport variants can legitimately have different segment IDs. Production allocation tests separately check that new sessions use the required fresh allocation path.

A parser-fixture builder and the production encoder must not be the only writers of valid examples. Include hand-annotated fixtures and valid alternative transport encodings to expose decoder/encoder agreement on a shared error.

### 5.3 Near-valid negative inputs

For an end-to-end semantic rejection, begin with a valid envelope and make one targeted defect. Repair unrelated framing, lengths, checksums and AEAD as necessary to reach the intended validator. Creating malformed bytes belongs in a test-only fixture writer, not an unchecked production proof constructor.

Some symbolic invalid graphs cannot be realized as self-consistent content-addressed envelopes without circular hashes, or will necessarily fail an earlier structural rule. Label those as internal graph-validator tests. Do not claim end-to-end cycle-detection evidence from an input rejected only for an ID mismatch, and do not weaken identity validation to get a desired test trace.

For a required guard, record a passing neighbor, entry into the relevant layer, the intended outcome, and the absence of prohibited downstream effects. Error classification can admit a documented set of equivalent integrity outcomes when the protocol does not require one exact precedence. It must not conflate unsupported input, missing dependencies, work-budget deferral and malformed input.

### 5.4 Test verdicts and feasibility

A proposed scenario is not passing evidence. Use statuses such as `planned`, `blocked-policy`, `blocked-implementation`, `blocked-platform`, `implemented-not-run`, `passed`, `failed`, and `inconclusive`. Execution results are tied to source, binary, fixture, model and platform revisions, not a manually maintained permanent green checkbox.

For below/at/above tests, first verify that each input is representable while other limits remain valid. A record's fixed width or another tighter bound can make the exact numeric maximum unreachable. Record that dependency and test the nearest legal edge plus the lower-level length guard; do not advertise a full end-to-end at-limit success that cannot exist.
## 6. Turn v2's static safeguards into production contract tests

Use these alongside the first vertical slice, not as a prerequisite to building a large type hierarchy.

| ID | Challenge | Positive companion and dynamic follow-through |
|---|---|---|
| TC-STATIC-01 | Ordinary separate client attempts ID/graph-role substitution, receipt construction, premature publication, or raw-path publication | Matching roles compile; real issuer creates usable evidence; context-mismatch cases still reject |
| TC-STATIC-02 | Attempt multiple consumption of a unique descriptor/ticket; attempt to reconstruct authority through decoding | Legitimate transfer compiles; cancellation/drop releases resources without committing data or consuming a user action |
| TC-STATIC-03 | Add a synthetic limit case without updating the independent exhaustive fixture mapping | Fully mapped case compiles; `CaseIterable` alone is not credited; actual boundary cases remove a production guard to test sensitivity |
| TC-STATIC-04 | Inspect the actual dependency/API/build surface for unchecked issuer paths, production test-key injection, safety-disabling flags, and unreviewed FFI exceptions | Required narrow adapters still build and run in debug/optimized configurations |

**Runner contract.** Build the real module normally and compile the client without `@testable import` or access-control bypasses. Check the diagnostic category and intended source location; require its valid companion to compile. Missing module, syntax error, deployment failure, or unavailable compiler option is a setup failure, not evidence of the restriction. A signature/access change that makes a negative client compile must fail CI.

Apply source checks to actual production targets and bridge declarations, not just a demonstration package. Pin each unsafe exception to its owner, rationale and corresponding runtime tests. Do not use a global unchecked conformance to make the tests compile.

Swift Testing supports parameterized cases and runs them in parallel by default. Give every case independent directories, clocks, allocators and callback gates. Tests deliberately sharing a root run as one controlled scenario; do not rely on serialization of one suite to protect unrelated tests or external processes. [W4]

V2's isolated compiler probes do not satisfy TC-STATIC-01–04 for the production library. Repeat the restrictions against the eventual actual module and optimized build configuration. [P6]

The [typed Runtime boundary qualification](typed-runtime-boundaries-validation.md)
applies these challenges to the actual module: private acceptance-batch issuance,
required command provenance, separate automatic/reviewed compensation consumers,
and owned commit/lifecycle variants. Compiler challenges remove one case from
each concrete receive-error switch and require the exhaustive-switch diagnostic
at that switch. A separate literal table checks the durable reason codes and the
retryable errors. These checks complement compatible-type/wrong-context calls,
independent SQL/byte observations and assertion-specific mutations; compiler
access restrictions alone establish construction boundaries.

## 7. Core contract cards: implement these first

Each card supplies the test's semantic setup, a controlled schedule, independent observations, and a named code challenge. The schedules are implementation instructions, not a proposed interpreted scenario language. `G1`, `G2`, and later gates refer to §13. Names such as E/P/D are fixture labels; actual IDs must be generated or checked using the protocol's rules.

### TC-CAP-01 — A faithful frozen action, not just durable bytes

**Gate/owner:** G1; command/capture adapter and codec owners. **V2:** §§4–6, 15. **Requirements:** PUB-01, DUR-01, HIST-01.

**Setup.** Open a valid fixture collection with note N and an untouched note U. Give every relevant field a distinct marker: N has body `A`, title `Old title`, at least one supported label, explicit format, and distinct display dates; U has different markers. Use the finalized date/label/content rules, not provisional defaults.

**Schedule.** Through the real command path, admit a saved edit changing N's body to `AB`; close/capture that group. Before its worker completes, admit a named rename to `New title`. Persist both complete groups, then reopen from current rows. In a second variant, mutate the original mutable Objective-C buffer after the adapter declares the first capture frozen.

**Expected observations.** The first group's before/after values describe the body edit and preserve every field outside that command's effect. Any command-owned display-date update is an explicit expected value, not assumed unchanged. The rename retains the body's new value and its own before/after title. Each group has exactly its actual member operations and scope; no named boundary disappears through coalescing. Reopen retains both groups and U unchanged. The already frozen snapshot is unaffected by subsequent mutation of its source buffer. The later live edit remains separately pending until its own barrier.

**Controls/challenges.** A legitimate same-open-group typing sequence may coalesce; do not expect a record per keystroke. Remove a title/label/format copy, alias a mutable input, substitute the later live before-state, or coalesce across the named boundary. The independent command/record assertions—not encoder round trips—must detect the defect. If field encoding is not frozen, mark the dependent variant blocked-policy.

### TC-DUR-01 — Earlier completion cannot clear later work

**Gate/owner:** G1; local runtime and main-thread bridge. **V2:** §§7, 11–12, 15, 17. **Requirements:** DUR-01, PUB-01, CKPT-01.

**Setup.** Valid retained baseline N=`A`, U unchanged. Admit/capture E: N=`AB`.

**Schedule.** Hold E's completion after a chosen real installation/pin boundary. While it is held, admit F: N=`ABC` and leave F pending. Release E's completion. Repeat with F being a Delete and with F affecting an additional independent field. A separate run terminates the process after E's complete barrier but before delivering its completion.

**Expected observations.** A delayed E completion reports only E's captured generations. It never reinstalls `AB` in the live store or clears F. The full E group and dependencies are recoverable after the barrier even without a callback. The untouched note survives. After F's own barrier, reopen recovers F as well and retains E historically. Do not expect F to survive a crash while it remains solely admitted RAM state.

**Controls/challenges.** With no F, completion correctly clears the captured pending generation; an implementation that never clears anything fails. Mutate the completion handler to clear by note ID alone or publish its old captured value. Roll back materialization in a variant: the acknowledgment and history result must not depend on its success; catch up before editable reopening.

### TC-DUR-02 — A dependent Delete cannot outrun its parent

**Gate/owner:** G1; dependency validator and acceptance issuer. **V2:** §§6–7, 11. **Requirements:** DUR-01, DELETE-01, HIST-01.

**Setup.** Start with N=`A` and an owned associated plaintext file where the profile permits it. Admit edit P to `AB`, then Delete D that observes P.

**Schedule.** Exercise P and D as earlier/later members of one complete envelope and as external dependent envelopes. Hold the external parent's required durability boundary while allowing all other legitimate work. Try normal acceptance of D and its original-file removal obligation. Terminate at each reached boundary. Separately deliver a received child before its parent and later supply the exact missing evidence.

**Expected observations.** D may be admitted locally before persistence, or received/parked remotely, but no acknowledgment, incoming application, completed external handoff, or original physical removal is authorized without durable required closure. A healthy same-envelope case succeeds atomically. A child received first becomes applicable after exact parent installation and pin coverage, without a second logical Delete. After a durable D, the old birth stays deleted on reopen; U remains unchanged.

**Controls/challenges.** Mutate parent testing from durable evidence to RAM/index presence or skip a closure member. The test must actually reach the relevant decision. If another invariant makes that mutation unreachable in the local authoring path, report that and exercise the receiving/recovery caller where parking is possible; do not force the correct implementation through an impossible phase. This card implements the substance of the reported `earlyDependentAck` counterexample. [P3, P5]

### TC-DUR-03 — Atomic acceptance preserves every branch and independent settings

**Gate/owner:** G1 core, G2 concurrent-history expansion; Local State and acceptance owners. **V2:** §§7, 11–12. **Requirements:** DUR-01, CKPT-01, REPAIR-01.

**Setup.** For G1, use a durable pin covering baseline history and a required descriptor not represented by segment ancestry. Prepare a settings update, then accept a later local action. For the G2 expansion, use two incomparable accepted branches before preparing the older settings update, then accept another branch. The latter variant specifically challenges frontier-union and compaction errors.

**Schedule.** Accept another complete branch, then resume the older prepared settings update. Race two prepared acceptance plans across suspended validation; one local SQL writer revalidates each plan. Inject failure inside/before/after history/index/pin/ready-work commits and again during recovery. Reopen after each permitted outcome.

**Expected observations.** Acceptance never regresses closure or loses required descriptors. A settings update modifies only its current field/group, not an old copied pin. Exact objects, complete membership, pin advancement and reverse-dependency wakeups are all committed or none accepted. Stored parked inputs are not accepted until all prerequisites validate. An ambiguous commit is resolved by exact identity lookup, not a flag or live-note check. Scope/pin correctness does not depend on derived rows; current-row failures do not retract a completed acceptance.

**Controls/challenges.** Compact a frontier by removing a locator that is actually ancestral: closure must remain unchanged and the valid optimization succeeds. Removing an incomparable leaf, comparing only sequence maxima, forgetting the independent descriptor, or committing an older captured pin must fail. Compare expanded sets rather than requiring one specific equivalent frontier serialization.

### TC-EVD-01 — Correct types, incompatible evidence

**Gate/owner:** G1; each evidence issuer/consumer. **V2:** §§6–8, 11, 15. **Requirements:** AUTH-01, DUR-01, PUB-01, CRYPT-01.

**Setup.** Obtain evidence through real issuers for two segments, two private stores with the same logical collection, and successive incarnations of one store. Use the real runtime to create these contexts; do not add an unchecked receipt initializer to production.

**Schedule.** Through controllable completion routing or a narrow internal consumer test, try: semantic evidence for A with durable bytes for B; a valid closure missing B's last dependency; a pin for the wrong store incarnation; an old in-flight completion after repair activation; and the same logical collection ID bound to a different physical root. Change one dimension at a time.

**Expected observations.** No mismatched combination produces acknowledgment, pin advancement, model publication, or physical authority. A missing-reference token remains usable to request evidence without implying the target exists. The matched combination succeeds. A newer valid pin covering A transitively is not rejected just because its literal frontier differs from A's original pin.

**Controls/challenges.** Remove each dynamic context/coverage comparison independently. Wrong-type compilation failures do not count for this card. A consumer genuinely unreachable from public clients can be tested internally, but at least one real end-to-end out-of-order completion must demonstrate correct routing through the actual adapter.

### TC-ASY-01 — Real actor/queue wiring, not only pure transitions

**Gate/owner:** G1 initial save, G3 complete bridge; runtime/execution owner. **V2:** §§12–13, 15. **Requirements:** ROOT-01, PUB-01, WAIT-01, DUR-01.

**Setup.** Instantiate the actual coordinators and blocking-I/O adapters. Arrange completion gates for sealing, SQL acceptance/pin commit, materialization and main-thread publication.

**Schedule.** Submit overlapping save requests while the first suspends. Submit settings/recovery work during a pin commit. Cancel or dismiss a UI request, then deliver its late completion. Deliver an already handled callback again at the adapter's event boundary. In the real application bridge, let an observer make an allowed synchronous call during notification/publication.

**Expected observations.** At most one local sealer is in flight per collection. No stale pin plan replaces newer history. Each owned operation retires at most once; callbacks cannot target a reused operation slot. Already admitted work survives dismissal. No observer sees a half-published note/index combination, and synchronous reentrancy cannot mutate through a half-committed publication. A noncopyable ticket dropped before admission does not perform a hidden action in destruction.

**Controls/challenges.** Remove in-flight reservation; key completion lookup only by reusable index; release resources on timeout before the accessor finishes; notify observers halfway through publication. Use named gates, not sleep-based races. Apple documents why actor assumptions must be rechecked after suspension; the synchronous application-callout case additionally comes from testing the actual bridge. [W3]

### TC-LIVE-01 — Local durability progresses with a stuck provider

**Gate/owner:** G1 synthetic, G3 real adapters; runtime owner. **V2:** §§11–12, 17. **Requirements:** ROOT-01, WAIT-01, DUR-01.

**Setup.** Healthy complete local store and unlocked key. Start a provider operation that has entered its actual blocking adapter and will not complete during the scenario. Start a large but valid history/index task in another variant.

**Schedule.** Admit and force capture of a new local edit. Permit its local effects to complete without releasing any provider callback. For background work, use a deterministic operation/work budget and require yields that let urgent local work proceed. Repeat through real execution resources to catch accidental queue sharing.

**Expected observations.** The exact local edit reaches its ordinary complete barrier and is independently recoverable. Provider failure creates no Work Offline prompt or local admission failure by itself. The maximum in-flight work and buffer counts obey selected implementation budgets. Progress resumes normally when provider completion is finally released; there is no duplicate operation or upload-as-durability claim.

**Controls/challenges.** An implementation that never starts provider work fails the entered-accessor witness. An implementation that refuses every local edit fails the positive admission case. Deliberately route both blocking lanes through the same serial resource or gate the local commit on upload: the recorded progress condition fails. A wall-clock watchdog terminates a wedged test but is not proof that the provider finished or that a correctness deadline expired.

### TC-BYTE-01 — Canonical identity is neither transport identity nor display equality

**Gate/owner:** G1 initial records, G2 all records; codec owner. **V2:** §§3–5, 9, 14. **Requirements:** CRYPT-01, HIST-01; Format-TODO §§1–6, 10.

**Setup.** Independently annotated canonical operation bytes and full envelopes for the finalized record variants. Include all semantically participating fields and exact parent IDs; use two canonically equivalent Unicode spellings as distinct stored bodies.

**Schedule.** Encode/decode on each supported implementation platform. Vary one identity-participating field while keeping the record otherwise valid. Re-encode the same logical operation with valid alternative external/intra-segment transport references and complete group placement. Vary allowed compression/nonce transport choices in separate fixtures. Feed nonzero-offset slices and mutable-source changes through the supported input boundary.

**Expected observations.** Exact expected preimages, semantic IDs, and complete consumption agree. Exact body spelling is preserved. Logical identity is invariant under valid transport representation changes, while the complete envelope's segment ID follows its actual bytes. The bytes hashed/authenticated and later decoded belong to the same owned immutable snapshot. Serialized raw sets use the specified comparator, not dictionary insertion order.

**Controls/challenges.** Omit an action ID or predecessor field from the shared traversal; hash a locator instead of its operation ID; normalize a body implicitly; calculate a length with character count; assume a slice starts at zero. Independent preimages and field sums detect a mistake even when encoder, size sink and hash sink share it. Alternative group packaging is a test fixture capability, not a new production repacking feature.

### TC-CRYPT-01 — Authentication coverage and semantic validation are separate gates

**Gate/owner:** G1 encrypted slice, G2 full variants; crypto/codec owner. **V2:** §§7–8, 14. **Requirements:** CRYPT-01, START-01.

**Setup.** Known-good envelopes and bootstrap descriptors under fixed synthetic keys with independently checked AAD, HKDF inputs and expected tags. Construct a fixture with syntactically valid header variations that do not automatically fail an unrelated expected-context check.

**Schedule.** Three distinct campaigns: (a) change a known authenticated field/ciphertext without changing its tag; recompute only the outer locator/hash as needed to reach AEAD; (b) correctly seal a semantically invalid payload and let all outer checks succeed; (c) supply a valid authenticated object under the wrong pinned collection/key/scope/profile or a public object to an encrypted context. For AAD fields that are necessarily rejected earlier, test exact AAD bytes at the crypto boundary instead of claiming downstream AEAD execution.

**Expected observations.** (a) never reaches payload/decompression work after failed authentication; (b) reaches the relevant semantic layer but produces no accepted prefix, candidate update, or unauthorized publication; (c) cannot change bootstrap policy or become usable wrong-scope evidence. Public checksums are never credited as authentication. An unknown outer frame is not described as authenticated; known authenticated framing with an unknown payload version retains its distinct unsupported outcome.

**Controls/challenges.** Remove a field from AAD; choose policy from the supplied suite byte; decode before authentication; skip semantic agreement after successful AEAD. Use actual invocation/effect observation at the relevant boundary and a healthy neighboring case. Malformed extra files may be preserved or quarantined as specified; the forbidden effect is acceptance/application, not all disk activity.

### TC-ACT-01 — Validate the complete writer scope, not the receiver's current view

**Gate/owner:** G2; action and graph validator owners. **V2:** §§4, 6–8. **Requirements:** HIST-01, START-01, DUR-01.

**Setup.** One scope contains incomparable actions A and B. Pending local action P was admitted after observing A but before B entered the applied view, so P depends on A, not B. The applied authoring view now contains P and B; its expected scope maxima are exactly `{P, B}`. A received-but-unapplied action Q and an unrelated scope R are also present. Build both honest authoring fixtures and correctly sealed incoming records with targeted metadata defects.

**Schedule.** Capture a new action using the actual authoring frontier. On receipt, vary scope parents: omit B, include Q, include R, include a nonmaximal ancestor, duplicate an ID, or give before/after values inconsistent with the member operations. Delay history-UI index loading while new authoring occurs. Give the receiving device additional concurrent history not declared by the writer.

**Expected observations.** Honest scope parents contain all and only the maxima represented by the writer's declared inputs, including relevant pending dependencies. They do not come from a partial UI index or all received objects. Malformed input is rejected rather than normalized into compliance. Valid incoming records remain valid when receiver Current differs; validation uses declared writer history, not receiver equality. Compact authoring evidence is ready before editing even if full candidate presentation is not.

**Controls/challenges.** Test antichain-only validation, missing pending input, use of the lazy UI index, and receiver-Current equality. Graph-invalid symbolic cases that cannot survive earlier wire checks remain labeled unit tests. No test claims to detect history the writer never declared or never observed; v1 does not authenticate a writer's private mental/session state.

### TC-SEM-01 — Ordinary edits preserve unresolved alternatives

**Gate/owner:** G2 core, G3 command callers; reducer and bridge owners. **V2:** §§6, 9, 12, 15. **Requirements:** HIST-01, PUB-01.

**Setup.** A birth has incompatible revisions A and B. The applied causal view knows both; Current represents A. Use actual valid fixture IDs and record expected heads independently. Add an independently edited conflict note U.

**Schedule.** Edit Current to E through body, title, label, format, external-editor-return, and selective historical-recovery paths as they are implemented. Persist, deliver to a second independent store, invalidate derived indexes, and reopen. Repeat with Current representing a valid equal-value set or two-input merge, and with a new head arriving between capture and proposed publication.

**Expected observations.** E's causal inputs and note predecessors remain distinct: in the incompatible case it supersedes A only. B and U survive. In the equal/merge case E retains exactly the represented inputs and provenance, not one arbitrarily chosen revision. A stale publication is recomputed rather than widening the captured choice. Neither path calls Apple disposition or emits a resolver action without the corresponding user command.

**Controls/challenges.** Fill predecessors from the applied causal frontier, or reconstruct them from all known heads after a delay. Both devices agreeing on that wrong result is not sufficient; concrete expected heads and preserved values must differ from the mutant. An explicit Use this version action covering captured heads is a separate positive control once its encoding exists. Copy-only disposition never supplies those supersession edges. Include temporary local Current-pin release without a new provider event; recheck actual Current and represented inputs even if causal frontier is unchanged.

### TC-SEM-02 — Automatic preservation can retract without erasing independent work

**Gate/owner:** G2 core, G3 projection feedback; reducer/ingestion owners. **V2:** §§6, 9, 16–17. **Requirements:** DELETE-01, HIST-01, PUB-01, CLEAN-01.

**Setup.** D0 is concurrent with edit E; another Delete D1 observes E. A variant has E → F with F concurrent with D1. Additional variants edit or explicitly copy the automatic E preservation before D1 arrives.

**Schedule.** Deliver actual envelopes in schedules exposing the temporary E copy, then D1. Include projection/materialization and reopen between deliveries. Hold a prepared retraction while the user admits an independent edit P. Deliver P to another store that already knows D1. Repeat with several source revisions sharing a deterministic preservation key, only one of which becomes covered.

**Expected observations.** The source birth remains absent. Untouched E preservation retracts after D1 when no eligible source remains; E remains historical. F survives in its variant. P survives pending publication fences and, after durability, recovery/remote validation against its captured originating evidence. One covered source does not retire a key justified by another uncovered source. Retraction emits no automatic Create/RecoverCopy/RetireConflict and no blind unlink; obsolete unchanged projections do not auto-import as a fresh birth.

**Controls/challenges.** Use per-Delete union, sticky derived presence, coverage of all descendants, or receiver-current eligibility to erase P. Preserve positive retraction and positive independent-survival witnesses. Do not assert monotonicity of derived live notes; assert retention of accepted evidence.
## 8. Feature contract cards: extend the same harness

These are required feature gates, not optional polish. Their execution waits for the relevant implementation and finalized formats; that dependency must not be reported as a passing skip.

### TC-ACT-02 — Reviewed compensation preserves the actual inverse

**Gate/owner:** G2 portable core, G3 command/review adapter. **V2:** §§6, 9, 12, 15. **Requirements:** HIST-01, PUB-01, DUR-01.

**Setup and schedule.** Use two distinct fixtures. In the ordered fixture, author A → B → C, Undo C, then review and approve Undo B; expect Redo of B's actual compensation before C's. In the value fixture, B renamed `Shopping` → `Groceries`, while an actually represented concurrent action supplies Current=`Errands`. Select fixed fixture inputs/IDs for which the documented Current-selection rule produces that value; do not override the reducer to obtain it. Invoke the real candidate selection, select B through review when eligible, and approve replacement with `Shopping`.

The concurrent value must be backed by real operations and declared parents—not silently injected into Current as unexplained state. Candidate derivation may return several choices; the test selects the intended eligible one rather than forcing a hidden action target.

**Expected observations.** The approved compensation records actual `Errands` → `Shopping`; its inverse restores `Errands`, not `Groceries`. Untouched fields and alternative revisions remain intact. The ordered fixture preserves the older redo sequence. Entering explicit Note History with otherwise equal bytes instead records independent recovery and follows its own redo policy. Cancel, no-op preview, and stale consent create no operation. A later value/candidate change invalidates approval; no automatic retargeting occurs.

**Challenges.** Misclassify reviewed Undo as historical recovery; restore the original forward after-value on Redo; discard the redo tail; compare only selected body rather than the affected field/member set. Kill before/after group/pin completion and reopen to inspect actual records and candidate continuation, not just menu labels. [P1, P3]

### TC-ACT-03 — Concurrent compensation and fresh-birth continuation

**Gate/owner:** G2; history/action reducer and runtime. **V2:** §§6, 9, 17. **Requirements:** HIST-01, DELETE-01, DUR-01.

**Setup and schedule.** Two independent stores both know A: `0` → `1`. While disconnected, each undoes A, producing U and V with separate action IDs. Exchange exact envelopes, then review Redo U to produce R (`0` → `1`). Attempt Redo V: its result is now a no-op. Dismiss, Undo R to produce S (`1` → `0`), and Redo S to produce T (`0` → `1`). Replay through actual acceptance and reopen, including child-first deliveries.

**Expected observations.** U/V both remain historical. A no-op creates no compensation, consumes no sibling and does not disable the opposite valid command. Commands remain reviewable while the relevant compensation family has a competing leaf. A separate independent action X observing U/V has its own family; its safe Undo/Redo can be automatic without reviving suppressed old redo or erasing the fork.

**Fresh-birth variant.** Concurrent Undos of Delete restore equal-valued notes under distinct births. Redo one deletes only that restored birth; Undo that Redo creates yet another fresh birth. The sibling survives. Inspect birth mappings and actual compensation targets across both stores, not body equality alone.

**Challenges.** Collapse equal action effects, share one global cursor, make every historical fork contaminate every command, consume the no-op sibling, or reuse the original restored UUID. Port the concrete expectations from the named concurrent-undo scenarios, preserving their distinction from native partial coverage. [P3, P5]

### TC-CAP-02 — Native coverage and composition survive the real application seam

**Gate/owner:** G3; AppKit/Objective-C bridge owner, with history/runtime owners. **V2:** §§6, 9, 12–13, 15. **Requirements:** HIST-01, PUB-01, DUR-01.

**Setup and schedule.** Create two saved spans with known before/after values, then issue a fine-grained native Undo that reverses part of a span and a variant crossing several captures. Introduce a valid remote rename between native preparation and invocation. Attach two views to one note, switch one view X → Y → X, close the initiating view after admission, and exercise real input methods through normal focus/commit/cancel handling. Compare prior typing → properly registered external localized/whole-body change → later typing → repeated Undo/Redo, including separate/coalesced groups. Test remote editor application during composition separately from local focus changes; verify unrelated note work can still reach durability.

**Expected observations.** Remaining-effect coverage describes the actual native compensation for every affected saved action. Reopen restores durable coverage and portable candidates, not native invocation objects. A remote causal candidate is not bypassed merely because native ranges remain valid. Observers do not duplicate logical actions; registered adapters for received history and derived merges do not author new portable actions. Late completion remains bound to the captured note and attachment generation. NV does not interrupt composition unexpectedly, lose input or treat internal text-storage notifications as completed actions. Prefer deferred remote editor application until a safe input boundary, then revalidation/ordinary merge rules; composition alone prompts nothing. The initiating view can release without losing admitted work.

**Challenges and limits.** Mark an entire span undone, duplicate an action on observer notification, bind late work to `currentNote`, or apply stale remote text across composition. Include actual `LinkingEditor`/undo-router paths and real IME exercises; synthetic span/separate-snapshot adapters do not mandate a committed-text buffer, custom composition state machine or universal crash-snapshot policy. Standard AppKit input behavior is the adopted starting point. Do not infer correctness from group-close notifications or adopt the unaccepted Undo Saved Edit fallback to make tests pass. [P1, P3, P5]

### TC-START-01 — Complete bootstrap and current-row startup

**Gate/owner:** G1 basic reopen and complete initial bootstrap/snapshot; G2 general snapshots, large imports and startup expansion; startup/codec owners. **V2:** §§7–8, 11, 17. **Requirements:** START-01, CKPT-01, HIST-01, CRYPT-01.

**Setup and schedule.** Use a genesis commitment for at least two distinct note values. Independently deliver descriptor, genesis/import batches, ImportComplete, snapshot root/pages and dependencies. Vary missing/duplicate/contradictory batches and pages. Separately start from returning stores with valid, lagging or invalid current materialization plus accepted unmaterialized work and previously parked inputs that become ready.

**Expected observations.** Fresh editable bootstrap requires the complete verified commitment and local closure. Complete snapshot preview remains distinct from editability. Returning startup drains ready work, applies the indexed accepted suffix, preserves required private settings and constructs the entire current-note/search model and compact authoring context from one consistent current-row capture. Invalid materialization requires reconstruction, not silent row omission or settings reset. A required unknown collection codec never becomes an empty editable result. A parked optional malformed extra does not suppress unrelated valid history.

**Wrong-result variants, kept separate.** A validly sealed **provider snapshot** with a wrong row/frontier must fail bootstrap/history verification; it is never installed directly as trusted private current rows. For local materialization, omit a deletion or a body-equal context update, or publish values under the wrong represented prefix: independently expected rows/context must fail. Test wrong scope/version, a rebuild changing the view epoch at an identical numerical prefix, concurrent acceptance/materialization during read capture and a stale final publication. Test current-cell decoder omissions against independent byte/semantic fixtures, not a digest of that decoder's own output. Healthy opens with no unmaterialized work must succeed with historical BLOB/operation reads forbidden. Derived-row invalidity requires reconstruction; shared/required database damage requires the store-repair classifier, never partial editable emptiness. [The selected algorithm](../LocalStore.md).

**Challenges.** Treat current rows as the pin, skip a sequence hole, trust a snapshot tag as proof of derived correctness, or load only the note currently selected. Test startup speed separately without weakening these assertions. [P1, P3, P4]

The [storage review witnesses](storage-review-follow-up.md) additionally cover
optional ready snapshots, repeated snapshot roots, multiple current-row decodes,
packed-envelope amplification, scoped commands, unapplied compensation batches
and nonfrontier damage followed by failed diagnosis writes/restart. Narrow
known-issue assertions expose the four deferred gaps; ordinary strict assertions
now cover interrupted diagnosis, envelope decoding and recovery graph reuse.
Passing content checks alone cannot qualify those work bounds. Their
compiler probes keep provenance exclusive and graph issuance private.

The implemented [interrupted verification increment](phase-4-improvements/durable-verification-recovery.md)
adds VR01–VR11 for durable replay obligations, final semantic-check coverage,
concurrent/stale completions, repeated recovery failures and scoped startup cost.
REVIEW-DAMAGE-1 is now an ordinary passing assertion. The
[validation report](phase-4-improvements/validation.md) records actual replay,
failed-write, compiler, process and model evidence, separately from the plan.

The [at-most-once decoding plan](phase-4-improvements/at-most-once-envelope-decoding.md)
adds ED01–ED11 for packed graph reads, exact occurrence coverage, duplicate
equivalence, captured-prefix races, worker failures and reconstruction. Per-object
observations require both at-most-once decoding and complete required coverage;
independent history/state expectations remain the semantic oracle. Implemented
qualification addresses REVIEW-HISTORY-2; graph reuse across recovery batches
has its own guarded consumer and observations below.

The [recovery graph-reuse plan](phase-4-improvements/recovery-graph-reuse.md) adds
RG01–RG12 for complete final-prefix reduction across unapplied batches, nested
ready-drain catch-up, connected compensation/conflict/deletion histories, target
interference, private-state preservation and fresh-process failures. Independent
history/context expectations accompany the one-graph assertion; each invalidated
attempt remains visible in end-to-end work counts. Implemented qualification
addresses REVIEW-HISTORY-3 before editable publication, with live
callers retaining their current route. The
[deferred benchmark backlog](phase-4-improvements/benchmark-backlog.md) keeps the
remaining four startup/scoped-query candidates separate from implemented coverage.

### TC-REPAIR-01 — Complementary copies repair private history first

**Gate/owner:** G2 local repair, G3 provider repair; classifier/repair/runtime owners. **V2:** §§7, 11–12, 17. **Requirements:** REPAIR-01, DUR-01, ROOT-01, CLEAN-01.

**Setup.** The old private store has G+L, the repository has G+R, and the surviving pin requires the closure G+L+R. All labels stand for independently valid exact objects; neither copy alone is complete.

**Schedule.** Diagnose through the real filesystem-to-health classifier. Build a fresh sibling private store. Interrupt copying, closure verification, Local State pin commit, and activation. Fail a second operation during recovery. During provider repair, create a competing compatible or foreign occupant at the captured destination. Repeat with top-level `NV Data` positively absent beneath the same retained root.

**Expected observations.** Only the exact validated repair union is used. The damaged private store is preserved. New private-store activation and any dependent provider-repair publication wait for a complete private closure and committed pin. New sessions allocate fresh action origin/writer epoch. A competing occupant is reclassified/preserved, never overwritten under stale authority. Healthy local closure can automatically recreate positively absent repository data, including unpublished durable objects, without a Restore control.

**Controls/challenges.** Remove R from every source: no claimed full repair or editable stale-current-row fallback. Make the private parent wrong-kind/unwritable: no invented alternate hidden store. Remove private-first sequencing, write in place, treat access-denied as absence, or fabricate a missing object; the concrete namespace/bytes assertions fail. Local RAM edits must first attempt urgent preservation; a provider-only copy is not evidence that they were saved. [P1, P3]

### TC-ROOT-01 — Physical ownership cannot be replaced by matching names or bytes

**Gate/owner:** G3, qualified per platform at G4; rooted-adapter owner. **V2:** §§7, 11–13, 15. **Requirements:** AUTH-01, ROOT-01, DELETE-01, REC-01.

**Setup and schedule.** Open and own root R. Prepare an operation, then move R and create a different directory at its original path with the same collection ID and identical protocol bytes. Deliver the old completion. In other runs move R without replacing it, replace an expected projection just before final effect, supply a symlink/wrong-kind leaf, and contend with a second local process. Test private-store ownership separately from repository ownership.

**Expected observations.** No old operation acquires authority over the replacement root or replacement projection. An already-entered accessor retains its own resources until it returns/fences; the test must not assume timeout instantly cancels its underlying OS work. Same-object moves preserve the supported continuity and lock lifetime. Acquisition stays nonblocking in the specified order; offline local operation does not bypass known root contention. No blind unlink occurs after a mere path/hash/UUID match or after restart.

**Challenges.** Reopen by pathname, equate collection IDs with root identity, close a borrowed ownership handle, or check a generation only before a delayed callback. Inspect actual target identities and contents from another process. A pre-check followed by ordinary path mutation is not accepted as a substitute for the specified expected-current primitive. Qualify the actual implementation against the separate safe-replacement/Apple API documents before counting this card passed. [P1, P3]

### TC-PROJ-01 — Body, stamp, and history arrive independently

**Gate/owner:** G3; projection/import/discovery owners. **V2:** §§8–9, 11, 15, 17. **Requirements:** DISC-01, PUB-01, DELETE-01, REC-01.

**Setup and schedule.** Create synthetic plaintext bodies and bounded stamps referring to known, missing and contradictory history. Deliver body/stamp/history in different orders; strip or copy the stamp; alter only the body; make two files carry identical provenance; and delay history beyond several quiet catalogs. Repeat with a trustworthy existing local association and with an explicitly chosen Import as New.

**Expected observations.** A matching stamp with missing history waits for named evidence, not a new birth. Once the complete exact represented state arrives, unique valid association avoids an echo Put. An ordinary eligible unstamped file imports automatically after the mandatory exceptions and narrow repair-candidate checks—not because quiet catalogs prove global newness. Missing metadata alone does not prompt. A copied stamp or matching digest does not authorize physical identity or deletion. Existing positive associations still allow legitimate external edits. Both automatic and explicit fresh imports keep their independent births if delayed evidence later reveals a duplicate. An oversized complete stamp is omitted, not truncated or replaced by a sidecar. [P1, P3]

**Challenges.** Stamp-as-authority, importing missing-history evidence on timeout, blanket prompting for every unstamped file, association solely by name, or swallowing a general write/readback error as optional xattr loss. Check actual operations/files and classifications, including successful ordinary auto-import and preserved late duplicates. A missing advisory stamp is supported, while uncertain body or required encoding/tag metadata installation remains unresolved. Reuse this card for obsolete automatic projections from TC-SEM-02 and TC-IMPORT-01 for pending decisions/restart.

### TC-KEY-01 — Credential and association cutover have different failure boundaries

**Gate/owner:** G2 value/bootstrap, G3/G4 signed platform integration; crypto/credential owners. **V2:** §§7–8, 11–12, 14–15. **Requirements:** CRYPT-01, START-01, REPAIR-01, BACKUP-01.

**Setup and schedule.** Create a destination through the real source-preserving creation/transition path. Fail before credential creation, after add-only creation, after readback, during association replacement, and after association installation before completion. Test keychain unavailable/locked, identifier collision, wrong readback value, wrong signing/access group, passphrase unlock, and same-key rewrap in separate cases.

**Expected observations.** No association refers to an unverified key item. An ambiguous cutover preserves possibly referenced credentials and source data. Locked/unavailable is not corruption or grounds for deletion. Restart requires normal key/bootstrap validation. Rewrap adds a same-key descriptor rather than falsely revoking old secrets. Fresh writer epochs/origins do not resume allocation from copied state, while retry of previously sealed objects retains exact bytes.

**Challenges.** Commit association first, delete the source credential on a destination failure, downgrade after failed unlock, or reseal on publication retry. Instrument actual creation inputs to confirm key/epoch allocation paths, but do not call finite noncollision tests a proof of randomness. Keep deterministic nonce seams out of the shipped API/binary configuration.

### TC-UI-01 — Apple disposition, review, and history are separate commands

**Gate/owner:** G3/G4; resolver/lifecycle/AppKit owners. **V2:** §§7, 12, 15. **Requirements:** REC-01, HIST-01, PUB-01, WAIT-01.

**Setup and schedule.** Enter conflict-badge recovery, Note History, and Undo/Redo review using equal visible preview bytes. For Apple conflicts, hold each of the four gates: admission, local group/parent barrier, exact plaintext installation, and final coordinated source/member check. Change source/member/root/file generation, dismiss/reopen the view, and deliver a late result. Test empty versus failed Apple enumeration while an NV-head conflict remains.

**Expected observations.** Apple setters occur only for captured applicable members after all additional gates; a later successful fresh query verifies Apple's disposition, while failed enumeration is not empty. History/review calls no Apple setter and disposes no NV head merely because they share a view. An empty Apple query cannot clear an NV-head conflict. The badge invokes an embedded read-only NSTextView-equivalent replacing LinkingEditor; × always dismisses. Preview and Cancel do not admit actions; dismissal after admission preserves pending work. Late completion never reopens the view or overwrites newer text. Wait/error states are per version, attempts are bounded, and re-presentation automatically retries exhausted applicable work without an explicit Retry button or overlapping accessor. Apple handles/consent are not portable persisted history.

**NV-copy variant.** Run reciprocal Save as new note on two stores. After exact durable preservation, only the selected revision leaves unresolved attention; no source Put/Delete/Keep Current or supersession is emitted. Source reduction stays independent, so the original plus two recovered copies may remain, including duplicate bodies. Completed dispositions survive copy edits/deletion and reopen; new descendants remain reviewable. Before completion, a modified/deleted candidate cannot count as exact reusable copy evidence. Source deletion is governed independently. The policy is adopted; only dependent codec/integration work remains. [P1, P3, P4]

**Challenges.** Substitute local acceptance for the extra file gate, widen the member set on retry, treat query failure as empty, infer command mode from matching text, subtract copied heads from source reduction, or recreate a deleted completed copy. Actual UI/accessibility/keyboard/IME qualification remains required; none of these tests permits Apple version removal.

## 9. Remaining scenario backlog and caller coverage

The cards above are deliberately small. Extend them with the following named cases rather than multiplying every dimension into one universal scenario. Each row inherits the near-valid input, positive control, independent oracle, and mutation obligations of §§3–5.

| ID / gate | Setup and stimulus | Required observable result / targeted challenge |
|---|---|---|
| TC-DUR-04 / G1 | Sweep actual SQL transaction/VFS write/sync/commit outcomes, including persistent failures and interrupted recovery | No premature acknowledgment/partial group; previous accepted closure survives; exact retry identity persists. Mutate early acknowledgment, omitted ready enqueue, split pin/acceptance or ignored commit failure |
| TC-DUR-05 / G1 private, G3 provider | Private duplicate exact BLOB versus contradictory bytes under one identity; provider equal unqualified final, conflicting/wrong-kind occupant and nested writer directory | Private duplicate acceptance allocates no new batch; contradictory bytes fail. Provider equality alone does not establish durability; preserve foreign occupants and perform required namespace barriers |
| TC-DUR-06 / G2 | Delete/materialization-loss plus removal of a pinned leaf or descriptor; unrelated invalid extra; total Local State loss in a distinct scenario | Required missing evidence blocks editable success until repair; unrelated extra does not block complete known history; total pin loss does not invent undisclosed-history knowledge |
| TC-BYTE-02 / G1–G2 | Truncate every short fixed fixture at each byte; invalid counts/tags/order/duplicates, overflow lengths, nested trailing data and invalid UTF-8 | Typed rejection without traps, partial application, unbounded allocation or accidental normalization. Retain valid neighbors and intended-layer reachability |
| TC-LIMIT-01 / G1–G2 | Below/at/above each finalized object, descriptor, stamp, passphrase and record bound; normalized rather than input character count | Correct per-limit outcome at the real entry point; no overly large read/allocation before bound enforcement. Exact unattainable record sizes are documented rather than faked |
| TC-LIMIT-02 / G2 | Same valid long graph with small/large work budgets, resumed repeatedly, plus a wide frontier near its representation ceiling | Identical eventual valid history under fair local processing; budget yields are not malformed history; no age/depth cap or dropped parents. Overflowing representation receives specified actionable outcome |
| TC-ZSTD-01 / G1–G2 | Both suites with authentic envelopes around short/long output claims, truncation, concatenated/skippable frames, dictionaries, unknown content sizes, oversized windows and trailing bytes; genuine valid compressed examples and independent writer checks | Exact [single-frame profile](../Encryption.md#compression-profile), bounded expansion and window, no frame interpretation before authentication. Legacy zlib bytes are rejected by the new codec; epoch-4 recovery remains separately tested |
| TC-MERGE-01 / G2 | Exact LF/CRLF/non-normalized Unicode, repeated lines, empty/unterminated bodies, strictly separated/touching intervals, equal/one-sided long bodies | Exact reference output or review; 10,001-token two-sided case requires review, not invalid note. Opaque rich equality/one-sided variants are deferred with that codec, not a prerequisite to plaintext work |
| TC-MERGE-02 / G2–G3 | Two heads with unique base; multiple best bases; third/dominating head arriving during preparation; equal-value heads | Complete represented IDs preserved; no pairwise three-head folding; stale derived results not published; no randomly minted merge operations |
| TC-ACT-04 / G2 | Bulk action where one member is invalid/stale/unsupported; complete valid neighbors; repeated retry after partial I/O | All members and record agree or no group is accepted; no easy-member-only compensation; oversized groups explicitly split before admission, never silently across segments |
| TC-ACT-05 / G2–G3 | Restore a named Recently Deleted entry; fail/pause barrier; delete the fresh restored birth; generic historical copy; concurrent restores | Source row excluded only by complete durable named restoration evidence; generic copy does not hide it; later Delete yields a new entry, not old-entry resurrection; simultaneous distinct births survive |
| TC-DISC-01 / G2–G3 | No presenter callback, callback-before-visibility, coalesced callbacks, new writer directory, sequence holes, renamed valid duplicates | Bounded discovery eventually adds disclosed valid evidence under stated retry opportunities; no callback/high-water-mark completeness inference; no duplicate semantic effect |
| TC-START-02 / G2–G3 | Healthy local closure with generic offline/full/permission/timeout versus positively disclosed missing newer/required evidence; disclosure before versus after editing starts | Only specified startup disclosure can offer Work Offline; later disclosure never revokes healthy editing; exact locally retained evicted copy creates no wait |
| TC-START-03 / G2–G3 | Total private store loss with complete repository; explicit root selection; unknown orphan objects and missing key variants | Fresh local store/pin/origin/epoch; portable history reconstructed; no old physical permissions/native stack restored; no automatic attachment by collection ID |
| TC-PROJ-02 / G3 | External disappearance while confirmation is open; file returns, note changes, or remote committed Delete arrives; stale Delete/Restore click | No premature removal; candidate revalidated; committed Delete uses its separate semantics; Restore after committed deletion has a fresh birth |
| TC-IMPORT-01 / G2 classifier, G3 complete path | [Adopted import/pending matrix](../Verification.md#external-file-admission-and-pending-recovery--adopted-policy): ordinary new files, unrelated missing notes, per-note active path/exact nonempty-content candidates, missing/copied provenance; latest B versus admitted frozen A; competing/no-op associations; A→B→C projections; repeated crashes before/after operation/pin/receipt; later Delete | Ordinary eligible inputs import automatically; exceptions take precedence and late births remain independent. Retain latest/frozen ownership through private replacement failures; recover exact admitted operation before rescanning even if its birth was later deleted; never replay consent or allocate another birth for lost receipt. Receipt settlement requires fresh source accounting and the actual chosen projection; no-op repair emits no Put. Retiring accepted A for B never clears intended C. Mutate blanket prompting, heuristic aliasing, early snapshot release, live-note-only retry lookup or stale claim/receipt acceptance |
| TC-COPY-01 / G3 | Repository-only copy with no source private store, unknown text files and retained old actions/deletes; unreadable placeholder; source text changes | Exact captured inventory preserved or explicitly reported incomplete; no private-state prerequisite or fabricated current-state genesis; unavailable dependencies do not forbid preserving available bytes |
| TC-COPY-02 / G3 | Recovery Save As during local failure with admitted unsaved work; current-state export; source changes during capture | Repository-only bytes do not claim to save RAM edits; urgent local barrier or disclosed current-state recovery export; source data remains until verified transition |
| TC-CLOSE-01 / G3 | Close with pending edits/external-editor handoff; materialization failure; pin/settings failure; provider wait; cancel/retry; old callbacks after switch | One close owner; local failure retains app/work; materialization failure alone does not fail durable quit; Quit Without Waiting preserves saved unpublished objects; no recursive last-chance save |
| TC-PRIV-01 / G3–G4 | Synthetic title/body/path/bookmark/secret markers through success, malformed input, key errors, preview, repair and export | No disallowed marker in production diagnostics, provider encrypted namespace, current/private clear payload, temporary outputs or prohibited indexes. No claim of whole-process zeroization from marker absence |
| TC-RICH-01 / G3–G4 preservation boundary | Existing rich or attachment-bearing legacy inputs presented to a plaintext-only destination; unsupported format/conversion and failed migration | Preserve the supported legacy recovery/export path and source bytes; explicitly reject/disclose unsupported conversion before cutover, never flatten or fetch resources silently. Attachments are unsupported; new RTF/HTML codecs/rendering/identity tests are deferred pending their separate decision |
| TC-PERF-01 / G4 | Fixed realistic note/body/history fixtures, cold/warm reopen, small/large tail, current-cell decode bounds, provider backlog, KDF and active typing | Complete current/search readiness and measured costs against selected baseline; no asynchronous search substitution, truncated current rows/history, or disabled validation to meet a budget |
| TC-PORT-01 / G4 | Same fixture corpus in debug/optimized builds on target architectures/OSs; older OS executable smoke; cross-platform exchange | Identical specified semantic bytes/IDs and outcomes; actual shipped binary launches; filesystem/credential/projection qualification remains separate |
| TC-LEGACY-01 / G3–G4 | Existing epoch-4 open/recovery/export tests plus new independent destination migration failure cases | Legacy contract preserved; genuine legacy export remains current-state-only; no modern shared compatibility archive or mutation of the source on failed migration |

### Sweep the real callers of a shared boundary

A passing helper test does not establish correct caller input construction. Maintain a short table of actual symbols once implemented:

| Shared responsibility | Callers that must be exercised |
|---|---|
| Admission/capture | Native typing and formatting, title/labels, programmatic changes, external-editor return, create/delete/import, history recovery, resolver choice, native/portable compensation |
| Complete local acceptance | Local authoring, received evidence, restart incorporation of extra finals, initial bootstrap, fresh-sibling repair |
| Private-state replacement | Retained-pin advancement, settings/cursor changes, root/credential association, repair activation |
| Exact filesystem effects | Provider object creation, projection replacement, original-snapshot deletion, database activation/backup, repository copy and repair; private row mutations use SQLite transactions |
| Main-thread publication | Incoming reduction, local completion, history-index completion, automatic-copy retraction, close/switch and preview completion |

Run the boundary's core scenario through every applicable caller, concentrating on different capture/context construction rather than copying its entire unit suite. Keep required tests for each mutation path visible even when the final library funnels them through one function. [P3, P6]
## 10. Mutation testing: demonstrate the suite's sensitivity

### 10.1 Initial challenge set

Apply small reviewed patches to an isolated production build, not to the reference oracle. A mutation manifest records its target source/revision, exact patch, intended invariant, required reachability witness, and test IDs. The shipped build must contain no permissive mutation switch.

| Mutation | Changed behavior | Required detecting cases |
|---|---|---|
| M01 | Emit acceptance before the verified retained-pin barrier | TC-DUR-01, TC-DUR-03, TC-DUR-04 |
| M02 | Count a RAM-only external parent as durable | TC-DUR-02 |
| M03 | Clear pending state by birth alone or reinstall a captured old body | TC-DUR-01, TC-ASY-01 |
| M04 | Replace Local State from an older captured pin/settings snapshot | TC-DUR-03 |
| M05 | Match receipt context by collection ID but omit store incarnation/object coverage | TC-EVD-01, TC-ROOT-01 |
| M06 | Derive note predecessors from all causal knowledge | TC-SEM-01 |
| M07 | Validate scope antichain/maximality but omit completeness | TC-ACT-01 |
| M08 | Target the original action/birth rather than the actual compensation | TC-ACT-02, TC-ACT-03 |
| M09 | Keep automatic copies permanently or erase independently edited preservation | TC-SEM-02 |
| M10 | Omit a semantic field from the shared canonical traversal | TC-CAP-01, TC-BYTE-01 |
| M11 | Omit an authenticated header field from AAD or trust the incoming suite | TC-CRYPT-01 |
| M12 | Remove/misroute a real length/normalization/decompression guard | TC-LIMIT-01, TC-ZSTD-01, TC-BYTE-02 |
| M13 | Block local work behind provider execution or remove work yielding | TC-LIVE-01, TC-LIMIT-02 |
| M14 | Ignore an unacknowledged installed final on recovery or accept authoritative derived rows | TC-DUR-01, TC-START-01, TC-DUR-06 |
| M15 | Publish provider repair before private closure/pin activation | TC-REPAIR-01 |
| M16 | Replace/delete by remembered pathname after identity change | TC-ROOT-01, TC-PROJ-02 |
| M17 | Bypass import exceptions on a quiet catalog, alias by stamp, or require confirmation solely for missing metadata | TC-PROJ-01, TC-IMPORT-01 |
| M18 | Commit destination association before verified credential provisioning | TC-KEY-01 |
| M19 | Replace reviewed compensation with generic historical recovery | TC-ACT-02, TC-UI-01 |
| M20 | Restore only the note effect or only the action/index update | TC-ACT-04, TC-CAP-02, TC-ACT-03 |
| M21 | Call Apple disposition after local acceptance but before exact file installation | TC-UI-01 |
| M22 | Reject every operation, never acknowledge, or never expose the risky feature | Positive/progress companions for the affected feature |

M20 must be a compilable and reachable production-code defect, such as omitting a record from framing or its recovered index update. Do not invent an impossible torn logical member inside an authenticated atomic envelope and call it a real persistence outcome.

### 10.2 Verdicts

Run the unmodified baseline first with the same fixtures and configuration. If it does not pass, mutation sensitivity is not interpretable. Classify the mutant result precisely:

| Result | Meaning |
|---|---|
| Targeted runtime failure | Intended boundary reached and independent named assertion detects the incorrect result |
| Compile-blocked | The attempted fault violates a static contract; useful static evidence, not a runtime detection |
| Survived | Intended path reached and the test did not detect the change; investigate the oracle or actual redundancy |
| Unreachable | Scenario did not reach the altered decision; no claim that it caught this fault |
| Unrelated failure | Build/setup/fixture failure, unexpected crash category or wrong assertion; not the intended evidence |
| Inconclusive | Execution/trace exceeded its budget or could not establish the witness |

An input-triggered crash or sanitizer finding can be the intended failure for a memory-safety mutation. A generic timeout is not credited for an unrelated correctness mutation. For liveness challenges, record the specific unmet progress condition and the blocked event chain; the watchdog itself is only a termination mechanism.

A surviving mutation can reflect a second valid protection. Document and independently review that explanation, or add a feasible input that distinguishes the guard. Do not delete a real safeguard or export an unsafe constructor simply to manufacture mutation coverage. Completion requires no unexplained critical survivors, not an arbitrary global percentage.

### 10.3 Challenge the harness too

Add small self-tests: a missing named gate is an error; changing one expected byte fails; a denied call at an earlier layer is not credited as a deeper semantic rejection; a no-op fault injector is detected; an always-durable virtual disk fails its persistence examples; an omitted required scenario fails test discovery; and a bogus compiler failure is not accepted as a contract diagnostic.

These self-tests do not replace review of the observer/model. They prevent common ways the automation could go green without exercising the intended boundary.

## 11. Expand systematically without building an intractable universal test

The [phase-3 schedule and observation matrix](phase3-schedule-observation-matrix.md)
applies these rules to editable multi-head state, deletion/preservation, conflict
copies and portable Undo/Redo. It names the feature fixtures, real storage cuts,
independent observations, progress witnesses and mutation obligations, including
four connected lifecycles and selected three-writer schedules. Its entries are
qualification requirements; executed evidence remains in the increment reports.

### 11.1 Exploration order

Start with exact hand-scripted schedules. For each short baseline, sweep one failure or one intervening event across every applicable named boundary. Next add persistent failure after that boundary and a second failure during recovery. Then enumerate delivery and completion permutations for small fixed histories. Add seeded generated histories and faults only after the existing cases are sensitive to their named mutations.

Do not cross every codec, history shape, OS, fault and UI event in every run. Choose interactions where one dimension changes the meaning of another: parent durability × Delete; acceptance/pin commit × settings; capture × named action; actor suspension × root/store change; stamped projection × delayed history; native coverage × saved action; authenticated payload × semantic defect.

A bounded enumeration report names the history, enabled event choices, maximum requests/crashes and explored schedules. Sampled testing records its seed and limits. Neither is labeled exhaustive over the program. Hash-table iteration, time, identity allocation and unmodeled runtime scheduling must be explicit sources of nondeterminism; saving a seed alone does not control them.

### 11.2 Failure reduction and replay

Store the full schedule as well as the seed. Reduce failures by removing commands, objects, deliveries and unrelated effects while preserving fixture validity and the target witness. For missing-dependency tests, preserve the intentional defect. For cryptographic semantic tests, re-establish the surrounding valid framing/authentication using the test fixture path.

A minimized failure is accepted only when it reproduces against the relevant binary/configuration and still reaches the same named invariant. Do not minimize it into an easier earlier rejection. Preserve the original trace, reduced trace and reduction decisions.

### 11.3 Metamorphic properties that fit this protocol

| Transformation | Valid expectation |
|---|---|
| Duplicate valid receipt/delivery; valid renamed transport duplicate | One semantic effect; required bytes retained; no echo action |
| Permute delivery of a fixed complete valid history, then allow local work to settle | Same independently expected histories/heads/derived values/candidates at the comparable final frontier |
| Change only valid transport representation | Same semantic operation identity; envelope identity follows bytes |
| Lower only a resumable work budget | Same eventual result after sufficient fair local work, with more deferrals rather than invalid history |
| Invalidate/rebuild current materialization | Same retained-history-derived result and independently preserved private state |
| Add an unrelated scope or immutable evidence outside a captured operation's applicability | No accidental cross-scope effect; only the actual declared freshness dependencies may invalidate the operation |
| Change display timestamps without changing causal structure | No timestamp-selected content winner or candidate order; display metadata may legitimately change |
| Repeat a no-effect preview/cancel sequence | No durable action, mutation, branch consumption or provider disposition |

Do not assume that live derived notes are monotonic, every valid operation commutes with every other, every temporary Current is identical on both peers, or every undo is a bytewise inverse of the original forward command. Review and actual-compensation semantics deliberately make some of those assertions false. [P1, P3, P6]

### 11.4 Fuzz campaigns

Separate targets for bounded outer framing, known plaintext payload parsing, action/reference validation, projection stamps, decompression, and structured history interpretation. Include genuine valid seeds and count whether the intended decoder/validator layers are reached; a campaign rejecting every input at magic or AEAD is not deep semantic coverage.

Keep production crypto and semantic validators intact in end-to-end runs. A test-only authenticated-payload target is useful for speed, but report that it bypasses outer authentication. The library's ordinary entry points must remain unable to bypass it. Verify the selected libFuzzer/sanitizer instrumentation with a deliberate failing smoke target before interpreting a quiet campaign as evidence. [P6]

Run ASan/TSan where the selected target supports them, and applicable Clang instrumentation on the C dependencies. Unsupported sanitizer/target combinations are not passing runs. Test optimized, production-like binaries as well: test hooks, assertions, scheduling and memory behavior can differ. Avoid promises to recover from arbitrary process OOM; test explicit resource bounds and scoped failure responses instead.

### 11.5 TLA+ connection

Retain the active/shared/retired/investigative disposition of the existing models. Start by extracting the concrete expected histories and external schedules from the documented scenarios; no general model-to-Swift translator is required. [P5]

| Model family | Production connection | Still separate |
|---|---|---|
| ImmutableSegmentDurabilitySafety / SegmentDeletionSafety | TC-DUR-01–06, real pin/closure bytes and acceptance | Actual persistence contract and arbitrary histories |
| CausalUndoRules / PortableCausalUndoSafety / ConcurrentUndoExecutionSafety / NativeCausalUndoBridge | TC-ACT-01–05 through real framing, acceptance and commands; partial/native causal coverage, actual inverse chains and restart | Actual AppKit attribution, deferred rich formats and arbitrary graph bounds |
| SegmentMergeSafety / SegmentDeletionOrderingSafety | TC-SEM-01–02 and TC-MERGE-01–02 | Exact LF kernel and actual file echo path |
| NVConflictCopySafety | TC-UI-01's representation-only reciprocal-copy variant | Exact copy/slot codec, physical installation and Apple-member disposition |
| SegmentBootstrapSafety / RepositoryRepairSafety | TC-START-01–03, TC-REPAIR-01 | Truthful OS classification, keychain and physical barriers |
| ProjectionStampSafety / CurrentVisibleReconciliationSafety / SeparateFileDeletionSafety | TC-PROJ-01–02, TC-ROOT-01 | Actual catalog/metadata/identity primitives |
| ExternalFileLifecycleSafety / PendingReferenceSafety / ExternalAssociationSafety / ProjectionTransitionSafety | TC-IMPORT-01 and TC-PROJ-01–02 | Concrete private bytes, classification/installation and full two-store history |
| ExternalRecoveryBridge / ProjectionRecoveryBridge / CompensationOverlapBridge | TC-IMPORT-01, TC-PROJ-01–02, TC-ACT-02–03 and pin/completion races | Bounded inlined bridges, not an arbitrary-history/OS/AppKit refinement |
| SharedNoteViewOwnershipSafety / NativeUndoSpanSafety / ReviewedUndoSafety | TC-CAP-02, TC-ACT-02, TC-UI-01 | Real AppKit, input-method, view lifetime and responder behavior |
| LocalDurabilityLaneIndependence | TC-LIVE-01 | Concrete execution resources, scheduling implementation and finite test budgets |

Replay the **environment choices** of a broken-model trace and allow the correct production code to reject/park/defer. Do not directly command it to “acknowledge early” merely because the broken model did so. A separately mutated production build supplies that defective internal transition.

For implementation-to-model checking, include critical effect/acknowledgment observations rather than projecting only final Current. Check the projection with known-invalid traces and do not map “receipt exists” to “barriers occurred.” Matching finite projected traces is evidence, not a whole-code refinement proof. The existing compound bridges already cover bounded pin/reference/settlement, projection and compensation races. Consult their recorded limits before adding a model for a genuinely uncovered composition; do not duplicate them or rerun an assumed primitive and call the primitive verified.

## 12. CI, result artifacts, and platform qualification

### 12.1 Execution tiers

These are proposed jobs behind the existing test entrypoint, not claims that the commands already exist. Select exact budgets after measuring them; no runtime estimate or test-count target substitutes for coverage of the named contracts.

| Tier | Required work | What fails the tier |
|---|---|---|
| Change/PR | Build/static clients; deterministic golden and completed-feature contracts; directly affected curated mutations; applicable model/reference/legacy checks | Missing required discovered tests, failed baseline, wrong negative-test diagnostic, violated outcome, unexplained survivor or protocol/fixture drift |
| Scheduled extended | Full named contract set; failure/completion sweeps; small-history permutations; seeded generated cases; fuzz/sanitizer smoke and campaigns; selected optimized runs | Reproducible defect, unexamined flake, unreachable claimed challenge, incomplete required run or artifact loss |
| Release candidate | Full required feature gates; actual target binaries; signed credential/provider integration; real application crash suite; current platform qualification and performance/legacy checks | Any unqualified supported capability, unresolved policy affecting enabled writers, missing critical implementation bridge, or unexplained critical mutation survivor |

Use one definition of the required discovered tests per enabled gate. A filter selecting zero tests is an error. A test renamed or omitted from registration cannot remain covered merely because an old ledger row says it exists. Do not automatically retry failures until green; retain first-failure artifacts and distinguish a test defect, an implementation race, and environmental unavailability.

### 12.2 Evidence bundle per scenario run

Record the scenario/variant ID; normative anchors; tested production entrypoints; source and binary identifiers; compiler/language/SDK/deployment settings; dependency and Swift codec revisions; fixture/expected-output digest and provenance; seed plus explicit schedule; fault location and reachability; permitted disk-model assumptions; low-level effect trace; observed acknowledgments/publications; before/after/reopen inventories; named assertions; mutation disposition; and remaining untested platform assumptions.

Use synthetic content only. A test artifact may contain intentionally known fixture secrets, but production diagnostics must remain restricted. Importing a real customer failure requires a separately appropriate handling policy; do not make uploading notes or secrets a routine CI requirement.

The evidence ledger links requirements to current runs. It is not a permanently cumulative percentage: a changed issuer, codec, fixture oracle, observer, filesystem model, or toolchain can invalidate a previous result. Report conformance as a set of specific established/blocked obligations, not one green status for the entire storage engine.

### 12.3 OS and capability matrix

| Dimension | Required evidence |
|---|---|
| Swift core byte/semantic conformance | Same reviewed fixtures and expectations on each claimed architecture/platform; debug and optimized selections |
| macOS 11.5 deployment | Launch and exercise the actual built library/bridge on that OS, including runtime/linking and used API paths—not just a deployment flag |
| Test-runner availability | Check separately from app deployment; when a runner cannot run on the oldest OS, execute representative core assertions in a compatible standalone target and report that coverage explicitly |
| Writable filesystem support | Qualify exact installer/replacement/locking/directory-barrier operations and filesystem/mount assumptions with actual resources |
| Credentials | Signed app and actual selected Keychain query/cutover behavior, including lock/unavailability/collision cases |
| Provider integration | Synthetic two-device folder observations, exact received hashes, missing/skewed metadata and lifecycle behavior; provider-upload status is not a receiver oracle |
| Plaintext and legacy-input boundary | Real imported/exported bytes, metadata and external editors; explicit unsupported/conversion handling with legacy/source preservation. No new attachment or RTF/HTML codec work |
| App behavior | Synchronous search readiness, complete current bodies at editability, native undo/composition, keyboard/focus/accessibility and dismissal behavior |

An unqualified platform may exercise portable codec/semantic tests without being claimed to support writable storage. Do not substitute Linux success for a Darwin barrier or signed Keychain result. Record unsupported platform features explicitly; do not infer a fallback from a failed capability probe. [P1, P3, P6]

### 12.4 Real crash and power-loss procedures

For application crashes, the parent driver waits for a reached child boundary over a control channel, terminates the child without graceful-close code, then launches a fresh production opener. Acknowledgment observation stays in the parent solely as an assertion input. Do not send its list to recovery.

For persistence loss, qualify what a VM reset, virtual-disk fault layer, machine restart, or physical power interruption actually removes. A guest process kill is not power loss; a VM reset may preserve host write caches. Record the exact cache/barrier assumptions and the external observer's acknowledged operations. Separate later-media-corruption tests from loss of unsynchronized state. Existing documented OS/API probes must be linked to the precise production adapter version they qualify. [P3, P5, P6]

Live provider tests use only the explicitly authorized synthetic test subtree described by proposal 5. Do not convert a unit-test failure into global provider resets, account sign-outs, quota modifications, or deletion of unknown artifacts. Peer-observed actual bytes and identities, not sender progress metadata, judge the tested transfer. [P3]

### 12.5 Performance as a conformance constraint

Measure complete current-note/search readiness, launch/replay work, peak memory, pending-to-local-barrier latency, KDF cost, projection backlog, directory scans/object reads, and retained growth on fixed reviewed workloads. Separate performance thresholds from semantic limits and specify the machine/filesystem/cache state used.

Establish the baseline and agreed thresholds before optimizing. A faster path that skips snapshot validation, drops ancestry, resets settings, truncates bodies, blocks local work behind provider coordination, or defers live search fails correctness regardless of its timing. Conversely, an implementation that continually rejects/recomputes unrelated operations or never finishes bootstrap fails its positive progress/readiness scenarios.

## 13. Implementation backlog and gates

### G0 — Establish an honest test boundary

**WP0: Pin sources and qualify tooling.** Reuse the repository test/build/API-contract assets linked in §1. Record normative snapshots and active model dispositions. Implement the adopted package-runner/Makefile integration; confirm compiler/dependency/deployment settings. Resolve unfinished format choices only where needed for the first supported record slice. Inventory real mutation entrypoints and acceptance/private-state issuers.

**Deliverable:** a short symbol-to-responsibility map, existing commands that actually run, source/fixture provenance, and an initial list of blocked items. **Exit:** an ordinary separate client and representative target executable build; no claim yet of storage conformance.

**WP1: Add the minimum observations and fixtures.** Create a complete valid baseline collection with N and untouched U, required bootstrap/completion evidence, independent initial values, and named low-level effect gates. Implement the small disk-model examples and observer negative controls. Add TC-STATIC-01–04 for actual available APIs.

**Exit:** the fixture's independent inspector and available hook/static-client self-tests pass; missing hooks/fake compiler failures/incorrect expected bytes fail the harness. Opening that baseline through the production codec/installer is a G1 exit, after WP2/WP3 implement the path. Unsupported records remain unavailable rather than assigned temporary production tags.

### G1 — Qualify a local saved-edit slice before expanding the abstraction

**WP2: Minimal value, action, byte and encrypted envelope path.** Freeze the necessary complete records and before/after references, not every deferred feature. Implement TC-CAP-01, TC-BYTE-01–02, TC-CRYPT-01, and applicable limits/zstd cases. Run actual selected primitive known-answer tests and bootstrap framing checks. Use both profiles before qualifying both.

**WP3: Actual installer, pin commit, reopen and completion.** Implement TC-DUR-01–05, TC-EVD-01, TC-ASY-01's local variants and TC-LIVE-01. Exercise actual lower-level I/O and fresh-process recovery; run M01–05, M10–14 where applicable. Cover settings-versus-pin concurrency, not just object creation.

**Exit:** complete acknowledged groups and required closure survive the specified reopen boundary; unacknowledged complete finals are rediscovered; no stale completion clears newer work; every critical challenge has a meaningful disposition. At least one actual OS run connects the installer to its selected primitive contract. Full physical power-loss qualification remains distinct at G4.

**Scope control:** G1 is a development gate for the supported slice, not permission to ship proposal 5 without required history, repair, source-preserving legacy/unsupported-input handling or other enabled-feature gates. New rich codecs are deferred and attachments unsupported. A symbolic or public-only prototype does not qualify both profiles.

### G2 — Qualify portable history, two-store exchange and private recovery

**WP4: Extend through actual bytes.** Add TC-ACT-01–05, TC-SEM-01–02, TC-MERGE-01–02, TC-START-01–03, TC-REPAIR-01's local portion, TC-IMPORT-01's classifier and TC-UI-01's portable NV-copy variant, plus remaining limits/discovery cases. Use two independent store instances and a fresh-process variant, not shared in-memory indexes. Run M06–09, M14–15, M20 and relevant earlier challenges. Extend model connections only for the specific compositions.

Use the [phase-3 matrix](phase3-schedule-observation-matrix.md#4-feature-matrix)
for the portable semantic portion of WP4; retain startup/repair and application/
provider obligations in their respective later gates. Preview-only computation
and unsupported editable materialization do not satisfy a connected feature row.

**Exit:** independently expected histories, heads, compensation/birth mappings and startup outcomes match through real codec/acceptance/reopen paths; valid child-first delivery progresses after dependencies; derived rows never replace retained-history or physical authority. All enabled record layouts and semantic rules have frozen fixtures. Unfinished snapshot verification and dependent record encodings remain blocked, not guessed; representation-only conflict-copy and targeted import/pending policies are already adopted.

### G3 — Qualify provider, application and lifecycle integration

**WP5: Exercise actual callers and OS observations.** Add real actor/queue/bridge portions, TC-CAP-02, TC-ROOT-01, TC-PROJ-01–02, full TC-IMPORT-01, TC-KEY-01, TC-UI-01, copy/close/privacy/legacy-input cases and full caller coverage. Replay selected abstract scenarios via their real application commands. Add M16–19 and M21, with progress controls.

**Exit:** invalid authority never reaches the wrong physical object; actual admission and native/history routes preserve meaning; signed credential transitions preserve source recovery; provider or derived-materialization failures do not become global local-save failures. The existing UI restrictions and human review gates remain intact. Actual AppKit/IME tests are not replaced by the portable core simulation.

### G4 — Release qualification

**WP6: Run the required matrix and archive evidence.** Execute existing build/core/platform/legacy commands identified in WP0, the completed Swift/scenario jobs, applicable model/reference suites, optimized/sanitized selections, two-device provider tests, target-OS executables, persistence qualifications and performance workloads. Record exact configurations and unresolved capabilities.

**Exit:** no enabled feature depends on an unresolved normative choice, an unimplemented required bridge, a passing skip, an unqualified claimed platform primitive, or an unexplained critical mutation survivor. Document tested scope, not global freshness, arbitrary-history refinement, or guaranteed recovery from erasure of every copy.

### First implementation slice to schedule

Assign WP0–WP3 first, using direct Swift definitions and the existing test infrastructure. No schema generator, custom scheduler runtime or external specification language is planned. The first review should see one concrete command captured correctly, complete bytes/ancestry/pin persisted, a held completion followed by a newer edit, a fresh reopen, and the specific faulty implementations rejected by the tests.

That review can identify whether a further type restriction or focused simulator case removes a demonstrated risk. Expand only at the next concrete gap, without a parallel executable schema or general testing framework.

## Appendix A. Conformance obligations for v2

These summarize the testing obligations paired with v2 and the phased plan. They are not a claim that the corresponding tests or issuers have been implemented.

| Location | Add or change |
|---|---|
| After §15 | Add a command-to-capture conformance obligation: frozen note values, before/after/action membership, coalescing boundaries, native attribution and mutable-buffer ownership must be checked independently of downstream persistence |
| §7 | Require issuance/use/context-substitution tests for each evidence type; distinguish tests of a consumer from tests earning evidence through the production issuer |
| §11 | Add an independently observed acceptance predicate and complete caller coverage, including restart and repair; explicitly challenge concurrent pin/settings replacement |
| §12 | Test the real adapter at suspension/completion boundaries and synchronous observer callouts; a pure state-machine pass cannot qualify actor/queue wiring or a final publication section |
| §16 | Keep declared obligations separate from revision-bound execution evidence; require success/reachability and mutation witnesses rather than accepting populated ledger fields |
| §10 | Record boundary input feasibility and intended validator reachability; no earlier-error masking and no universal assumption that at-limit means accepted |
| §5 | Retain literal expected preimages and field sizes independently of the direct Swift definitions/shared traversal; same-codec agreement is not an independent oracle |
| §17 | Specify the fault model, separate application crash/persistence loss/later corruption, qualify observers with negative controls, and forbid recovery from receiving harness-only history |
| §17 | Translate model environment schedules and independently expected observations before investing in general trace tooling; preserve forbidden intermediate effects in projections |
| §18 | Interleave the minimal semantic subset with real local acceptance testing; do not wait for the entire semantic kernel before exercising the first durable vertical slice |

## Appendix B. Requirement-to-scenario coverage map

This is an initial index of obligations and cases, not a claim that every clause of the specification has been mechanically enumerated or that the cases have executed. Keep the detailed source anchors and actual caller symbols in the implementation ledger.

| Adopted requirement | Primary scenario evidence |
|---|---|
| AUTH-01 | TC-EVD-01, TC-ROOT-01, TC-REPAIR-01, TC-START-03 |
| START-01 | TC-START-01–03, TC-ACT-01, TC-CRYPT-01, TC-KEY-01 |
| DISC-01 | TC-DISC-01, TC-PROJ-01–02, TC-START-02 |
| PUB-01 | TC-CAP-01–02, TC-DUR-01, TC-ASY-01, TC-SEM-01–02, TC-UI-01 |
| REC-01 | TC-UI-01, TC-PROJ-01–02, TC-ROOT-01 |
| DUR-01 | TC-DUR-01–06, TC-EVD-01, TC-CAP-01, TC-LIVE-01, TC-ACT-04 |
| CLEAN-01 | TC-DUR-04–05, TC-REPAIR-01, TC-SEM-02, TC-CLOSE-01 |
| ROOT-01 | TC-ROOT-01, TC-ASY-01, TC-LIVE-01, TC-CLOSE-01 |
| CKPT-01 | TC-START-01, TC-DUR-03, TC-DUR-06, TC-CLOSE-01 |
| WAIT-01 | TC-LIVE-01, TC-ASY-01, TC-START-02, TC-UI-01 |
| DELETE-01 | TC-DUR-02, TC-SEM-02, TC-ACT-03, TC-ACT-05, TC-PROJ-02, TC-ROOT-01 |
| HIST-01 | TC-CAP-01–02, TC-ACT-01–05, TC-SEM-01–02, TC-MERGE-01–02 |
| CRYPT-01 | TC-BYTE-01–02, TC-CRYPT-01, TC-ZSTD-01, TC-LIMIT-01, TC-KEY-01, TC-PRIV-01 |
| BACKUP-01 | TC-COPY-01–02, TC-START-03, TC-KEY-01, TC-LEGACY-01 |
| REPAIR-01 | TC-REPAIR-01, TC-DUR-03, TC-DUR-06, TC-START-02–03, TC-ROOT-01 |
| IMPORT-01 | TC-IMPORT-01, TC-PROJ-01–02, TC-CAP-01, TC-DUR-03, TC-REPAIR-01 |

## Sources and evidence basis

### Project sources

**[P1]** [iCloud Drive specification](../../iCloud-Drive-Support-Spec.md): normative requirement registry, input/content scope, local durability, startup/repair, causal values, targeted external imports, history/undo, lifecycle, encryption and backup.

**[P2]** [ADRs](../../adr) and [CONTEXT](../../../CONTEXT.md): retained-history authority, ownership, independent lanes, compensation, repair and canonical terminology.

**[P3]** [Implementation](../Implementation.md), [Protocol](../Protocol.md), [Encryption](../Encryption.md) and [Verification](../Verification.md). Especially production/history tests, adopted copy/import/pending behavior, compound bridges and remaining implementation gates. Statements about previously executed checks are source reports, not new results from this strategy.

**[P4]** [Format TODO](../Format-TODO.md), §§1–10. Unfinished byte layouts/validation choices are not silently frozen here. Existing limits and the 124-byte envelope remain constraints; plaintext-first scope and no attachments apply.

**[P5]** [Model coverage](../../tla/Proposal5-Coverage.md), [model guide](../../tla/README.md), [whole-set audit](../../tla/Storage-Protocol-Audit.md) and [runner](../../tla/check-segment-models.py): dispositions, actual models/configurations, bounds and controls. Source existence and historical counts do not become new execution evidence.

**[P6]** [Swift library v2](swift-storage-library-proposal-v2.md), [phased plan](swift-storage-implementation-plan.md), [AGENTS](../../../AGENTS.md) and [integration tests](../../IntegrationTests.md), for the portable package, application/legacy/deployment and test-driver boundaries.

### External primary sources retained from the original strategy

These support the original testing/tooling discussion, not new API experiments in this documentation correction or a claim that the proposed NV tests already work. Qualify the actual selected toolchain and platform paths during implementation.

**[W1]** SQLite, [How SQLite Is Tested](https://www.sqlite.org/testing.html), especially I/O error injection, crash testing, compound failures, mutation testing and journal-test VFS. Used as precedent for low-level observed failure testing and checking that guards affect outcomes; SQLite's transaction/recovery semantics are not imported into NV.

**[W2]** FoundationDB, [Simulation and Testing](https://apple.github.io/foundationdb/testing.html). Supports using deterministic simulation alongside separate live performance and hardware-failure testing, rather than treating simulation as platform qualification.

**[W3]** Apple, [Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/). Actor isolation does not preserve assumptions across suspension; synchronous actor-state changes and post-suspension checks address different concerns.

**[W4]** Apple, [Implementing parameterized tests](https://developer.apple.com/documentation/testing/parameterizedtesting). Parameterized cases and their default parallel execution; this strategy supplies the independent per-case resources and fixture obligations.
