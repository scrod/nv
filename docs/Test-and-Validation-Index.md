# Project test and validation index

This is the source-level index for all project phases, including the legacy app,
the portable NVStorage library, physical/provider adapters, formal models,
experiments and future application integration. It describes **what is checked,
how to run it, and which documents define or use it**. Qualification results remain
in the linked, revision-bound validation reports; inclusion here is not a passing
result or a release claim.

The [repository bookkeeping audit](Testing-and-Documentation-Audit.md) records
reconciled status, command and navigation issues, together with the resolved
experiment-retirement decision.

## Find an individual check

| Catalogue | Contents |
| --- | --- |
| [Swift Core tests](test-index/swift-core.md) | Every `@Test` declaration: canonical values, framing, cryptography, record layouts, history and reducer rules |
| [Swift Runtime tests](test-index/swift-runtime.md) | Every `@Test` declaration: ownership, transactions, saved actions, recovery, semantic commands, private state, snapshots, physical roots and transport |
| [Runners, fixtures and experiments](test-index/runners-and-experiments.md) | Make targets, independent byte oracles, schema tests, process schedules, benchmarks, platform/sanitizer jobs and fresh-process probe modes |
| [Compiler and mutation checks](test-index/compiler-and-mutations.md) | Restricted-construction, isolation/ownership/diagnostic probes and isolated production-source mutations, with their declared targets/expectations |
| [Native and legacy checks](test-index/native-and-legacy.md) | Objective-C/C scenarios, native probe functions/modes and named Apple API observations; epoch-4 recovery remains an active compatibility path |
| [Formal models and configurations](test-index/formal-models.md) | Every active/exploratory module, static `.cfg`, and expanded runner-defined TLC matrix row, including negative controls and reachability witnesses |
| [Document-defined checks](test-index/specified-contracts.md) | Contract IDs, scenario tables and validation requirements from the proposals/plans, including checks whose production callers are still future work |
| [Document references](test-index/document-references.md) | Expansion of each entry's direct, suite-level and governing-plan references; reverse lookup by document |
| [Source/support inventory](test-index/source-inventory.md) | Every inventoried source, fixture, fault hook, helper and build prerequisite, including files that have no independent test entry point |
| [Machine-readable catalogue](test-index/catalog.json) | Stable source/name IDs, parameters, commands, argument declarations, reference sets and source fingerprints |
| [Archived proposal-4 checks](tla/retired/impl-proposal-4/Test-and-Validation-Index-Archived.md) | Retired checkpoint/WAL models and configurations, kept with their historical guide rather than mixed into active coverage |

The generated catalogues are grouped by source file. Search a function name,
scenario label, contract ID, model name or runner path. Each row links back to its
source declaration. In particular, an aggregate runner's name is not a replacement
for the individual checks listed beneath it.

## Phases and their governing plans

The phase numbering is the [portable Swift roadmap](impl-proposal-5/plan/swift-storage-implementation-plan.md).
Family-level references in the catalogues supplement literal name/runner mentions:
earlier plans often describe a scenario before its eventual Swift symbol exists.

| Phase | Validation scope and where to start |
| --- | --- |
| Legacy / compatibility | [Integration guide](IntegrationTests.md), [native catalogue](test-index/native-and-legacy.md), `tools/test-epoch4-v5-compatibility.sh`. Original WAL/database/file-save tests qualify the supported legacy path, not segment-collection persistence. |
| 0 — boundaries and harness | [Language-boundary proposal](impl-proposal-5/plan/swift-storage-library-proposal-v2.md), [conformance strategy](impl-proposal-5/plan/swift-storage-conformance-testing-strategy.md), compiler/construction probes, harness classifier self-tests and independent-observer checks. |
| 1 — values and envelopes | Core declarations, independent fixture scripts, malformed/near-valid inputs, crypto/profile checks, zstd framing and codec mutations. See [first-save encoding contract](impl-proposal-5/plan/first-save-reopen-contract.md) and [zstd validation](impl-proposal-5/plan/zstd-codec-validation.md). |
| 2 — durable local store | [Local-runtime qualification](impl-proposal-5/plan/phase2-local-runtime-validation.md), [hardening](impl-proposal-5/plan/phase2-hardening-validation.md), [current-basis work](impl-proposal-5/plan/current-basis-validation.md), [receive/resumption checks](impl-proposal-5/plan/validation-resumption-results.md). Real SQLCipher, independent processes, ambiguous commits, pending generations, ready work and rejected prerequisites. The historically named `test-storage-phase2.py` now aggregates later-phase regressions too. |
| 3 — two-store semantics | [Schedule/observation matrix](impl-proposal-5/plan/phase3-schedule-observation-matrix.md), [qualification](impl-proposal-5/plan/phase3-validation.md), connected process tests and independent history inspection: edits, Delete, Restore, merge/preservation, conflict copies and causal Undo/Redo. |
| 4 — reconstruction and private recovery | [Data-safety contracts](impl-proposal-5/plan/phase4-data-safety-contracts.md), [bootstrap/reconstruction](impl-proposal-5/plan/phase4-bootstrap-reconstruction-plan.md), [received snapshots](impl-proposal-5/plan/phase4-received-snapshot-plan.md), [private repair/copy](impl-proposal-5/plan/phase4-private-state-repair-copy-plan.md), [current-row maintenance](impl-proposal-5/plan/phase4-current-row-locality-maintenance-plan.md), [improvements](impl-proposal-5/plan/phase-4-improvements/README.md). |
| 5 — physical/provider adapters | [Multipart implementation](impl-proposal-5/plan/phase5-provider-root-implementation-plan.md), [testing families](impl-proposal-5/plan/phase5-provider-root-testing-plan.md), P54/P55 matrices and result ledgers. Root ownership, immutable installation, bounded discovery, local/two-host exchange, coordination, startup and reassociation. [P5.6](impl-proposal-5/plan/phase5/06-repair-replacement-and-copy.md) and [P5.7](impl-proposal-5/plan/phase5/07-connected-qualification.md) retain their remaining actual-caller gates. |
| 6 — plaintext reconciliation | [Roadmap Phase 6](impl-proposal-5/plan/swift-storage-implementation-plan.md#10-phase-6--plaintext-projection-and-pending-file-recovery), `TC-PROJ-*` and import/pending requirements. Portable pending-state tests and models exist; full physical projection/association/deletion consumers are a separate integration obligation. |
| 7 — application interaction | [Roadmap Phase 7](impl-proposal-5/plan/swift-storage-implementation-plan.md#11-phase-7--application-capture-history-ui-and-lifecycle), `TC-CAP-*`, `TC-UI-*`, close/credential/legacy checks and AppKit undo experiments. Real capture, keyboard/IME/undo/resolver/quit behavior requires its actual callers and human review; headless tests do not qualify that UI. |
| 8 — release qualification | [Roadmap Phase 8](impl-proposal-5/plan/swift-storage-implementation-plan.md#12-phase-8--qualification-not-a-late-testing-phase), OS/filesystem/architecture/profile/debug/optimized matrix, dependency/security and privacy review, performance/resources, persistence-loss and physical-power-loss qualification. An unavailable platform or unperformed physical test stays an explicit gap. |

For synchronization meaning, use the [normative spec](iCloud-Drive-Support-Spec.md),
[ADRs](adr), [glossary](../CONTEXT.md) and [formal coverage map](tla/Proposal5-Coverage.md).
For filesystem/API effects, also use the [Apple API ledger](Apple-API-Contract-Validation.md)
and [Foundation replacement contract](Foundation-Safe-Replacement-Migration.md).
This inventory changes no requirement or modeled assertion.

## Running the checks

All commands in the catalogues are relative to the repository root. Values in
`<angle brackets>` must be supplied from the named runner's prerequisites; they
are not literal arguments. The argument lists below each Python runner preserve
its required inputs, defaults and optional selections. Use the real runner for
internal C/Swift probe functions: it supplies the fault schedule and independent
observer, not just a successful child exit.

### Portable Swift and independent validation

Build the pinned dependencies and use the Makefile's strict native SwiftPM entry
point rather than substituting system SQLite:

```sh
bash tools/build-storage-deps.sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --no-parallel'
```

Each Swift row gives its individual `--filter` command and declared parameter
matrix. Gated benchmarks/peer tests also name their enabling environment inputs;
path-valued inputs need the corresponding built probe or artifact directory.
An unenabled benchmark may be discovered yet skipped, so discovery alone is not
performance evidence. Boolean/profile parameters and platform conditionals are
part of the check's scope.

The broader regression driver connects schema/fixture/type/process work:

```sh
python3 tools/test-storage-phase2.py --configuration both
python3 tools/test-storage-runtime-mutations.py --configuration debug --only <declared-mutation-name>
```

The combined configuration executes both full Swift, compiler and process
campaigns. It shares exact native builds and configuration-independent check
evidence under the [campaign reuse contract](impl-proposal-5/plan/qualification-build-reuse.md).
Individual `--configuration debug` and `--configuration release` commands remain
available, with `--reuse-directory` for an explicitly shared campaign.

The driver is a convenient aggregate, not every optional job in this index.
Its `--mutations`, resource budgets and scratch-path options are listed in the
runner catalogue. Compiler clients need the built configuration's `Modules`
directory; process runners need its `NVStorageProbe`. For example:

```sh
python3 tools/test-storage-root-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-startup-process.py --binary NVStorage/.build/debug/NVStorageProbe
python3 tests/run-sqlite-schema-contract.py
```

Independent fixture checkers compare frozen bytes through separate encoders or
inspectors. Fixture regeneration options such as `--print` produce candidates;
they are not passing comparisons. Node-based checks require the Node APIs used by
their source. Process termination, simulated I/O/persistence loss and subsequent
corruption are separate fault classes; none substitutes for physical power loss.

### Native app, filesystems and Apple/provider checks

```sh
make -C tests run-core
make -C tests run-platform
bash tools/test-epoch4-v5-compatibility.sh
```

The native catalogue lists individual integration modes and the Makefile lists
their compiler/link prerequisites. Stress, leak, sanitizer, disk-image and live
provider campaigns are separately selected. Review their setup and cleanup before
running: they can create/move/delete synthetic files, mount images, invoke Finder
or TextEdit, or require a signed executable launched through LaunchServices.

Live provider tests require an explicitly authorized synthetic subtree, working
credentials and, for cross-machine claims, two independent hosts. Never point an
experiment at a real note collection. Account resets or real quota manipulation
are not a way to satisfy missing stimulus. `OBSERVE`/`READY`, an upload flag, or a
timeout does not establish the API capability the production caller needs. The
Apple ledger records interpretation, unsupported/inconclusive outcomes and the
applicable OS-specific qualifications.

### Formal checks

Set `TLC_JAVA` to the chosen Java executable and `TLC_JAR` to `tla2tools.jar`; see
the [TLA+ guide](tla/README.md) for tool prerequisites and campaign boundaries.
Examples:

```sh
python3 docs/tla/check-segment-models.py --java "$TLC_JAVA" --jar "$TLC_JAR"
python3 docs/tla/check-receive-models.py --java "$TLC_JAVA" --jar "$TLC_JAR"
python3 docs/tla/check-collection-startup-association.py --java "$TLC_JAVA" --jar "$TLC_JAR"
```

Each generated-case row preserves its actual tuple/dictionary of model, policy,
scenario, bounds, invariants/properties and expected outcome. Consult its runner
for tuple field order and effective fairness. Most TLC `--only` options are
**substring** selectors and can select several rows; mutation-runner `--only`
semantics are separately declared. Static `.cfg` entries give their exact command.
Shared specification modules are checked through their configured importing
models; an unconfigured module is not an independent completed campaign.

Finite exhaustive checks, temporal checks under stated fairness, policy
experiments, deliberate bad policies and reachability witnesses are distinct.
An expected counterexample is successful detection of the specified violation,
not a proof that the bad policy is safe. A witness deliberately falsifies a
`Never…` assertion to establish reachability. The optional full-temporal campaigns
remain optional expensive selections, not part of an unstated default run.
Cross-model word reuse does not establish refinement or automatic proof
composition. Retired proposal-4 configurations have their own archive catalogue.

## Scope, granularity and keeping the index complete

The source inventory covers project-owned files under `NVStorage/Tests`, `tests`,
`tools`, `docs/tla`, plus `build.sh`. It includes helpers and fixtures, while
excluding vendored upstream suites, dependency downloads, build products and
temporary qualification artifacts. Documentary cross-references scan the project
Markdown authorities/proposals/plans/reports, including the NVStorage README.

An entry is a named logical test, declared scenario/matrix row, compiler context,
mutation, runner stage, native observation, model/configuration or documented
validation requirement. These categories overlap deliberately: a runner can
execute a Swift test also listed individually; a compiler declaration can have
ordinary and same-module executions; a planned requirement can have several
witnesses. **Do not add the catalogue counts to obtain a number of distinct test
executions.** Parameterized executions, assertion statements and generated random
histories are described by their declaration/matrix rather than counted as an
unbounded list of separate tests. Internal helper entries say how their containing
runner reaches them.

The reference labels mean:

- **Direct:** a document names the check, source, module, runner or matching Swift
  selection. This is an explicit usage reference, not necessarily a per-assertion
  definition.
- **Suite:** an explicit source/runner dependency or the documented aggregate
  includes the check.
- **Governing:** a curated family-level plan/contract describes the behavior
  without naming that eventual implementation symbol.

Empty direct references are recorded honestly; governing and containing-runner
references provide the surrounding contract. A plan's prose is not silently
promoted into completed execution evidence. The document catalogue keeps table
rows, named contracts and testing-section requirements visible even when no
individual runnable command exists yet.

Regenerate and check without executing the underlying test suites:

```sh
python3 tools/generate-test-index.py --self-test
python3 tools/generate-test-index.py --write
python3 tools/generate-test-index.py --check
```

The generator performs source/AST inspection, expands finite literal matrices,
checks coverage of every Swift `@Test` and every `.tla`/`.cfg`, and fingerprints the
inventoried sources. Its restricted data evaluator reads scenario declarations;
it does not import or execute validation scripts. `--check` detects changed,
added or missing definitions and documentary references. Update curated family
references when introducing a new area. Qualification still requires the actual
commands, nonzero discovery, intended failure attribution and independent
observations prescribed by the [conformance strategy](impl-proposal-5/plan/swift-storage-conformance-testing-strategy.md).
