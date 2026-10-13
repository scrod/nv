# P5.7 — Connected qualification and Phase 6 handoff

Status: planned. Dependency: [P5.6](06-repair-replacement-and-copy.md) and every
earlier part's exit gate. Qualification begins as each part lands; this part
closes the combined witnesses and records their actual supported scope.

Use the testing plan's [connected schedules](../phase5-provider-root-testing-plan.md#7-connected-lifecycle-schedules),
[platform matrix](../phase5-provider-root-testing-plan.md#8-os-filesystem-and-api-qualification),
[work bounds](../phase5-provider-root-testing-plan.md#9-work-bounds-latency-and-resource-tests),
[mutation/compiler rules](../phase5-provider-root-testing-plan.md#10-compiler-boundaries-mutations-and-bounded-schedules)
and [completion gates](../phase5-provider-root-testing-plan.md#11-reporting-and-completion-gates).

## Connected runs

Execute S1–S6 through their real consumers in the same run, not disconnected unit
results. Keep stimulus controller, production adapter, independent observer and
fresh recovery reader distinct. Recovery gets surviving store/selection/unlock
inputs, not expected notes, acknowledgments or test-controller logs.

| Schedule | Combined path | Required independent evidence |
| --- | --- | --- |
| S1 | Retain/park → crash → prerequisites → stale received result versus newer edit/Delete → commit without callback → second crash | Exact history/membership, pending generations, live values and final causal alternatives |
| S2 | Early empty listing → no further hints → late writer/low prerequisite/renamed duplicate → ordinary discovery opportunities | Eventual exact retention/acceptance once, dirty/progress state and restarted continuation |
| S3 | Required work behind optional snapshots → checked publication → finite interference ends → background acceptance; fresh/verification companions | Actual admission/publication ordering, unchanged snapshot-only values and exact startup choices |
| S4 | Complementary private/provider union → pin/activation failures → second recovery failure → provider repair races | All source/unique private/displaced evidence, verified activation and complete known closure |
| S5 | Old backups → applicable Delete in either order → concurrent edit/fresh Restore → third branch/copy disposition | Bodies, births, represented inputs, source selection, unresolved attention, Recently Deleted and Undo/Redo candidates |
| S6 | Entered held accessor → local barrier → timeout/close/root change → late release → fresh reopen | Independent local progress, context fences, exact replies, resource ownership and retained unfinished work |

Add bounded generated combinations: two writers, one/two notes, two/three complete
actions, reordered/duplicated prerequisites, optional snapshots, rejection variants
and one then two failures. Enumerate applicable cut/delivery orders; add selected
three-writer cases and reproducible larger seeds. Preserve/minimize counterexamples.
Report exact bounds and fairness/progress conditions; finite schedule enumeration
does not establish universal provider convergence.

Compare with literal expected difficult histories and an independent small
reference calculation, as well as production fast/full agreement. Metamorphic
companions vary duplicate delivery, repackaging, restart, safe movement and work
budgets while preserving their justified outcomes. Agreement between two stores
alone cannot prove they retained the right data.

## Boundary, privacy and resource checks

- Run all applicable P5-* families for both profiles with debug/optimized builds,
  independent fixtures/schema checks, fresh processes and marked compiler probes.
  Challenge actual consumers with same-type wrong-root/store/session/profile/prefix
  evidence, including body-equal context changes.
- Run the testing plan's complete targeted mutation table. Require valid companions,
  nonzero discovery of every parameter, reached contested transition and the intended
  failure. Compilation errors, timeouts and unrelated failures are not successful
  mutation detections.
- Inspect actual final/stage/displaced/temp/export/error sinks using synthetic
  secret/body/title/path/bookmark markers. Check encrypted-provider confidentiality
  separately from both private databases' page encryption and password-free
  recoverability. Explicit plaintext exports remain confined to chosen destinations.
- Audit bridge/C lifetime, callback counts, memory aliasing and unchecked escapes;
  run applicable strict diagnostics, ASan/TSan and C sanitizers. Stress resource
  baselines after held accessors actually settle, not merely after timeout.
- Grow ordinary history, provider files, independent writers and snapshot frontier
  width separately. Measure healthy editable publication, local save, background
  discovery, acceptance and exceptional reconstruction. Freeze strict read/work/
  resource bounds and measured timing budgets without assuming constant-time
  catalogs, silently skipping validation or imposing a lifetime history limit.

Use existing model correspondence for scenarios. If a concrete change affects
modeled behavior, update/run its applicable configurations, preserving safety
assertions. Add a focused scheduling model only for a critical newly exposed
interaction. Treat genuine counterexamples as possible specification flaws;
do not weaken either the model or executable assertion to obtain a passing run.

## Platform and API evidence

Qualify actual executable paths on the declared macOS 11.5 floor, Intel macOS 14,
current supported arm64 macOS and portable/qualified writable Linux arm64 paths
as available. Record exact versions, architecture, compiler/SDK/deployment settings,
dependency revisions and packaging/runtime requirements. A compiler workaround,
test-runner limitation and successful library binary are separate observations.

Run per-operation filesystem/image checks, genuine image ENOSPC and detach/remount.
Run the signed LaunchServices harness and two real Macs in both directions with
actual peer-read bytes and observed materialization/root events. An unavailable
host or unobserved stimulus remains open/inconclusive. Neither provider brand nor
an upload indicator supplies missing evidence. Respect each host's authorized
fixture/cleanup scope; account resets and real quota manipulation are outside it.

Keep process termination, simulated persistence loss, machine restart, later
corruption and physical power-loss qualification separately labeled. Preserve
epoch-4 compatibility and applicable integration/build regressions. Broader
distribution/security/power-loss release gates remain visible in Phase 8.

## Exit report and handoff

Link one revision-bound report with sections for every P5 part. Its caller/capability
table records actual symbols/intent, command/cases, source/dependency/toolchain,
OS/filesystem/profile, cut/seed, independent predicate, mutation/assertion and
artifacts. Distinguish completed, partial, unsupported, failed, inconclusive and
unavailable evidence. Replace a known issue only after its production witness passes.

Complete Phase 5 only under the testing plan's seven completion gates. A supported
target's missing primitive or genuine policy contradiction requires a decision
before contract changes; preserve the example and continue unaffected work.

Hand Phase 6 qualified rooted read/install/replacement primitives, owned root
sessions, transport/discovery, health/repair decisions and source-preserving copy.
List its remaining plaintext admission/association/deletion/pending-file consumers
and Phase 7's AppKit/input/quit/switch consumers explicitly. Their qualification
must use these actual boundaries; the Phase 5 report does not claim finished UI or
complete plaintext interoperability.
