# External-file association choices: policy experiments

Experiments: 2026-09-07; narrow policy adopted 2026-09-08. Ordinary eligible external files import automatically, while association questions concern specific notes needing repair. Late duplicates are accepted; deterministic co-add, UUID reassignment and weaker file-deletion authority are not. Wider survey alternatives remain investigative, not runtime policy options.

The [spec](../iCloud-Drive-Support-Spec.md#separate-plaintext-files), [ADR-0014](../adr/0014-distinguish-logical-deletion-projections-and-conflict-disposition.md), and [proposal](../impl-proposal-5/Protocol.md#current-file-decision-matrix) now adopt the narrow targeted policy, including the subsequent active-transition and private pending-snapshot clarifications. `ProjectionStampSafety` replaces the obsolete blanket `NoAutomaticBirth` assertion with eligibility-at-admission and identity-preservation checks and corresponding controls. This is an explicit product-policy change, not a relaxation of provenance, deletion or physical safety to make a test pass. Other surveyed policies remain experiments; co-add remains disabled.

## Recommendation from the experiments

Keep the existing positive-association and explicit-provenance handling first. For a readable, eligible file that remains unclassified:

1. Consider only live notes whose **particular file relationship is missing or uncertain**. An unrelated missing note does not itself make the file ambiguous.
2. Offer association to a candidate if the file matches its **current intended path** or **exact, nonempty current projection bytes**. These are reasons to offer a choice, not reasons to perform an automatic association. A path match with changed/empty contents still qualifies; two otherwise unrelated empty bodies do not.
3. Show all qualifying candidates, not whichever note was encountered first. Evaluate each candidate's evidence separately. Do not pool one note's path match and another note's content match to pass a two-signal threshold.
4. Otherwise import with a fresh birth. Do not wait for an arbitrary quiet period. Explicit Import as New stays fresh regardless of similarity.

This is the `targeted` candidate, not a claim of statistically optimal UX. A rename with substantial edits and no surviving specific association evidence can still become a separate note. A deliberately copied template can still prompt if its exact contents match a missing note. The tests preserve both costs rather than pretending every user's intent is inferable.

**Not adopted:** the optional extension **old path plus exact historical projection bytes**, again only for a note needing repair (`historyPair`). Either clue alone is too broad in the comparison corpus. This catches a historical return but also prompts for an indistinguishable historical template copy. Access to historical descriptors must remain an asynchronous/indexed implementation concern, not a requirement to read every historical body during a scan or block normal editing. The active-transition refinement is different: it retains the one accepted representation still being replaced, not arbitrary history.

Event/name and partial-text-overlap combinations also catch additional edited renames, at the cost of additional prompts. They do not justify overriding the preferred hint-only scheduling policy. With hint-dependent classification, two Macs with identical note/file history but different event availability can make different prompt/import decisions. This is an additional UX trade-off, not proof of unsafe data loss by itself.

## What NV can observe

This inventory covers relevant signal **classes**, not every Foundation resource key or every possible classifier. Signals remain correlated and incomplete. The [canonical vocabulary](../../CONTEXT.md#7-note-files-and-provider-observations) distinguishes physical observations, portable projection descriptors, and immutable note history; none is a permanent physical-file identity.

| Evidence | Use in the experiments | Limit / source |
| --- | --- | --- |
| Collection/profile, eligible direct-child name/type/format, readable/materialized body | Mandatory eligibility/read gate, before heuristic classification | Existing filters; no directory, reserved `NV Data`, symlink, unsupported input or placeholder is turned into a blank note. Root authorization and parse/size bounds are lower-layer obligations. |
| Stable logical birth; current and historical revisions, accepted Delete, projection descriptors | Distinguish live/deleted/unknown history; exact known current projection can associate; a recognized deleted projection requires restoration handling | [Protocol](../impl-proposal-5/Protocol.md#separate-text-files-and-the-identity-limit). Local completeness is not global completeness. |
| Validated body-bound stamp with exact referenced state and locators | Keep known projections automatic; defer missing dependencies; distinguish copied, contradictory, malformed, foreign and stale stamps | Stamps are advisory; known bytes/history and uniqueness still matter. Body and stamp can arrive separately. |
| Current accepted local association, external-editor handoff, unique scoped nonzero file/document identity | Existing automatic edit/rename path | Modeled as a freshly applicable local scope plus unique matching ID. Real volume/session qualification and snapshot validation remain prerequisites, not inferred from a number. |
| Candidate note's missing/uncertain versus accounted-for relationship | Per-note candidate gate | “Missing” here means the previously established relationship needs repair, not that the pathname must currently be empty. A changed object at its former name can be uncertain. |
| Current intended path and older accepted paths | Separate heuristic signals 1 and 2 | Exact current path is useful for a repair *question*. An old path alone can be unrelated reuse. Case/normalization collisions take their own ambiguity path. |
| Exact current nonempty bytes and historical bytes | Signals 3 and 4 | Compared within the accepted format/encoding; no newline/Unicode normalization or digest-based identity invention. Equal contents can be independent templates. Derived merge/equal-value descriptors still need their full validated references in actual code. |
| Exact creation timestamp and modification timestamp | Separate signals 5 and 6 | Zero/unavailable is not equality evidence. Tokens represent exact comparisons, not clock ordering or “newer wins.” Copies can preserve timestamps. |
| Size, format/encoding and tags/labels | Signal 7: a matching low-specificity metadata bundle | Size/format are not independent confirmations of an exact-byte match. The bundle is deliberately one vote, not three votes for correlated metadata. |
| Historical/current FSEvents, related paths and IDs | Signal 8: a related path hint; unrelated hints are separate fixtures | No event-derived occupancy, remote deletion intent, freshness proof, or complete rename transaction. Gaps/asymmetry and scheduling are also tested in [CoAddRevalidationLab](CoAdd-Policy-Experiments.md#historical-hints-and-revalidation--coaddrevalidationlab). |
| Similar basename/title | Signal 9 | A cheap candidate-ranking clue, not sufficient to interrupt an otherwise unrelated import. |
| Raw file/document/provider ID equality outside valid scope | Deliberately weak experimental signal 10 | The sweep tests the cost of using it; the recommendation excludes it. Public provider identifiers are not portable across these tested hosts, and historical inode equality is not renewed local authority. |
| Partial text overlap | Signal 11, computed from two shared synthetic fragments in otherwise different bodies | Tests the *class* of similarity-based rules, not a production fuzzy-matching algorithm or calibrated threshold. Edited templates share fragments too. |
| Explicit user commands and live model generation | Fresh intent overrides heuristics; generation fences reject stale decisions | Explicitly choosing association is not simulated as an automatic heuristic merge. A later click still needs the actual application's validation and ordinary mutation path. |
| Root identity, current file/metadata snapshot, locally accepted history generation | Final admission fences in the dynamic model | Their concrete acquisition is assumed here, not an Apple cross-device compare-and-swap guarantee. |

Other available information does not add an independent association signal: provider “uploaded/current” status or a quiet catalog cannot exclude undisclosed history; writer clocks/sequences and preferences cannot identify the file; `NSFileVersion` identifiers/bodies remain contextual resolver evidence, not a portable incarnation key. Reverse provider lookup failure has no negative identity authority. Provider-side custom fields/services cannot be assumed available to an unrelated, provider-agnostic consumer. These exclusions follow the [API validation record](../Apple-API-Contract-Validation.md), not presumed API violations.

One concrete source-code trap: `_preparedNoteForCatalogEntry:fallbackNote:error:` passes the existing note's labels, encoding and creation date as decoding fallbacks. Those filled-in values must **not** become additional matching file evidence. A future classifier needs raw observed-value/presence information before those fallbacks; otherwise its own candidate assumption manufactures corroborating “matches.” The model's unavailable-value checks assume that distinction is preserved at its input boundary. This is a caller/integration requirement, not a newly validated parser implementation.

### Creation-time observation rechecked

Read-only `lstat` checks of the retained `FSEventsHistoryProbe` fixtures again found **different inodes with identical birth timestamps down to nanoseconds** after the probe's `NSFileManager` copy:

| Local fixture | Source / copied inode | Both birth timestamps, seconds + nanoseconds |
| --- | --- | --- |
| APFS `nv-fsevents-history-Cupwzd/tree/{B,CopyMoved}` | 215224374 / 215224383 | 1788812711 + 820638779 ns |
| Local iCloud directory `nv-fsevents-history-B2EL3K/tree/{B,CopyMoved}` | 215224398 / 215224406 | 1788812716 + 589648353 ns |

These are local observations on macOS 26, **not** a new cross-Mac timestamp transport experiment. They suffice to include copied equal creation times in the model. No new remote fixture or provider write was needed this turn. The existing [two-Mac metadata](Incarnation-Metadata-Experiments.md) and [historical event probes](CoAdd-Policy-Experiments.md#historical-fsevents-follow-up) supply the other adversarial observations.

## Model 1: `ExternalImportPolicyLab`

This is an exhaustive finite **decision-table exploration**, not a distributed protocol by itself. For each policy, `Init` selects a rule and `Evaluate` computes the decisions for all 60 scenarios. There is no physical-origin field in `Decision` and no supplied `plausible` Boolean. It compares actual synthetic file/note paths, bodies, historical sets, metadata, IDs/scopes, and event pairs. Mandatory provenance and eligibility branches precede the variable heuristic.

The sweep covers **22,528 rules**: every nonempty subset of eleven weak-signal classes, every threshold from one through that subset's size, both with and without the per-note repair gate. This includes single-clue, two-of-three, all-selected-clues and larger quorum rules. It is exhaustive over this family, **not** over arbitrary weighted scores, machine learning classifiers, all real histories or all Apple metadata.

Six named comparisons add blanket choice, automatic fresh import after mandatory exceptions, the narrow targeted rule, and targeted rules augmented by historical path/body, event corroboration, or partial-body corroboration. Two intentionally incorrect variants make a vote automatically assign identity, or pool votes across different notes.

The corpus contains ordinary new files, unrelated missing notes, healthy notes with similar extra files, empty/templates, identifier scope loss, same-path replacement, edited renames, historical returns, multiple candidates, copied/skewed/foreign stamps, missing/deleted history, placeholders, collisions, and explicit fresh import. Several pairs have **identical observations but different desired UX**: renamed file versus independent template, historical return versus historical copy, and edited rename versus similar independent contents. This deliberately prevents every desired outcome from passing simultaneously.

`WantNew` and `WantChoice` are independent fixture expectations, not classifier inputs. Counts are **synthetic scenario counts, not measured frequencies or error rates**. `CoreRepairs` expresses the chosen product priority for current-path/exact-current-content repair cases. `QuietNew` tests avoiding blanket confirmation from unrelated or superficial clues; these priorities are judgments, not discoveries made by TLC.

The runner writes `survey.json` containing every rule's mask/threshold/gate, extra questions, missed repair opportunities and two priority counts. It also reports the question/missed-repair Pareto frontier. A frontier is conditional on this corpus and these costs; it does not automatically choose the right product policy.

### Comparative outcomes

There are 26 new-intent fixtures, 15 repair-intent fixtures, and 19 mandatory-path fixtures. A missed repair means automatic fresh import where association choice was desired; it does **not** mean discarded contents. An extra question means an independent new file gets interrupted, not an unsafe automatic merge.

| Rule | Extra questions / 26 | Missed repair choices / 15 | Important cost |
| --- | --- | --- | --- |
| Blanket choice for unclassified input | 26 | 0 | Every new-file fixture is interrupted. |
| Automatic fresh import after mandatory exceptions | 0 | 15 | Also misses the common ambiguous replacement/rename opportunities. |
| **Targeted: missing/uncertain AND (current path OR exact nonempty current bytes)** | **3** | **8** | The missed cases need weaker history/similarity clues or expose no distinguishing clue. All four prioritized current-path/content repair fixtures are offered, with no questions in the 21 unrelated/superficial-noise fixtures. |
| Targeted + old path AND historical bytes | 4 | 7 | One extra historical repair and one indistinguishable copy question. |
| Targeted + related event AND old-path/historical-body/name corroboration | 4 | 6 | More sensitive, but hint availability affects classification. |
| Targeted + partial text overlap AND old-path/creation-time/event/name corroboration | 5 | 6 | Similar edited templates are interrupted too. |
| Two of current path / exact current bytes / creation time, gated to repair candidates | 2 | 13 | Misses **all four** prioritized repair cases; not a good replacement for the targeted OR rule. |

Within the threshold family, the targeted rule was the only one meeting both chosen priorities (all four core repairs, no noise-only questions). This is a **conditional model result**, partly driven by explicit single-noise fixtures; it is not a discovery that all other product policies are wrong. The composite `historyPair` also satisfies those priorities but lies outside the uniform threshold family. Event corroboration demonstrates a real additional choice, not evidence that FSEvents establishes identity or that its replay should become a correctness prerequisite.

The sweep's question/missed-repair frontier is `(0,15), (1,11), (3,8), (4,7), (5,6), (6,5), (7,4), (8,3), (9,2), (11,1)`. Composite predicates can improve on that family at particular points: `eventPair` reaches `(4,6)`, for example, but adds hint-dependent behavior. No surveyed threshold has zero misses: at least the no-clue repair is indistinguishable from an ordinary new file. Blanket review can cover it only by also questioning the new file.

The incorrect vote-to-identity rule fails on path-plus-creation-time coincidence. The pooled-votes variant fails when the path matches one missing note and the body matches another. Removing the per-note repair gate offers a healthy note; disabling known projection handling prevents a previously automatic path. These distinguish missing safeguards from mere UX trade-offs.

## Model 2: `ExternalImportAdmissionLab`

This model **instantiates the same classifier**, rather than substituting an oracle or duplicating its decision function. It connects classification to an import and cross-host history exchange. One Mac initially knows old creation `a`; another can observe its plaintext before receiving that history, and admit independent birth `b`. Optional Delete `d` targets the old birth, and optional edit `e` targets the fresh import.

| State | Purpose |
| --- | --- |
| Per-host `known`, `durable`, `incoming`; provider set | Separate validated application, local retention, dependency parking and independent transport. |
| Record parents, birth mapping and exact value tokens | Preserve identity and captured contents even when payloads match; keep edits and Deletes scoped to their own births. |
| Current file/body generation, stamp, root and note generation | Independently changing local evidence; metadata arrival is a real change distinct from body arrival. |
| Captured frame, decision, phase | Capture → prepare → final admission check; changed evidence rejects a stale attempt. |
| Acknowledged records and saved values | Audit successful local durability and recovery, not speculative captured bytes. |
| Crash/recovery and waiting witnesses | One restart and an actual wait → history arrival → re-observation → association trace. |

The implementation boundary is `NotationDirectoryManager` detached preparation and final `_commitDirectoryTransaction:` publication, adapted through proposal 5's mutation admission/local immutable-object barrier. `_matchAddedEntries:removed:usingDocumentIdentifiers:` supplies scoped unique local matching. The legacy `processNotesAddedByContent:removed:` automatic decoded-content identity fallback must become a repair question for uncertain segment imports; it is not the complete history-backed projection path. `_stageUnmatchedAddedEntries:removedNotes:` already imports unmatched legacy files automatically. The adopted segment policy keeps ordinary automatic additions with explicit provenance/repair exceptions. No production code is changed by these models.

The model splits capture, preparation, admission, local durable installation, publication, receipt, dependency application, crash and recovery. File/root/note/history changes can interleave with preparation; accepted history can also arrive **after admission**. An external file can change after admission without changing the already captured operation's contents. Parent-before-child application is explicit, not guaranteed by provider arrival order.

Safety checks require:

- Current file/stamp, root, history and note scope at admission.
- No provider publication before local durability; acknowledged imports/edits and their exact saved values survive restart.
- No late UUID reassignment or equal-payload suppression; the fresh import/its edit survives an old-birth Delete even when that Delete's author has heard of it.
- The old deleted birth remains absent, with dependency-closed applied history.

Reachability checks deliberately produce a **late duplicate**, preserve a fresh import after old-birth deletion, recover an edit, park a child before its parent, reject each kind of stale frame, retain an admitted snapshot after file change, and wait for history before successfully associating. Separate negative controls remove each fence, publish too early, lose recovered state, alter captured bytes, alias/suppress equal-content births, or stall installation/history resumption. Thus the tests do not pass merely by never importing or never progressing.

Conditional progress assumes fair local execution/recovery; cross-host delivery additionally assumes eventual publication, receipt and application. It promises neither a cloud deadline nor undisclosed history discovery. Waiting ends automatically when the **specific** dependencies arrive and validation succeeds, not because a timer proves newness. Lost root authority cannot be silently renewed by the model's re-observation action.

### Coverage boundaries

The new bridge models two hosts, four records, one receiving file, at most one body/metadata/root/note change of each selected kind, and one crash. The immutable-object durability barrier, codec, exact snapshot implementation and root authorization remain concrete integration obligations. This is not an unbounded TLA theorem or an implementation refinement proof.

It does not simulate general DAG/merge/undo history, private pending-byte persistence, a user completing association/replacement, two simultaneous choices claiming one note, real filesystem writes/unlinks, or provider conflict UI. The subsequent [ExternalFileLifecycleSafety](ExternalFileLifecycleSafety.tla) separately models snapshot/reference/reservation/history/receipt ordering and active-transition classification; it is not a composition of those steps with this entire two-host bridge. See [current coverage and integration tests](../impl-proposal-5/Verification.md#external-file-admission-and-pending-recovery--adopted-policy). A pending UI by itself never proves bytes survive external replacement or total private-store loss. Weak metadata cannot authorize a physical write here, but that is an excluded operation surface, not a demonstrated filesystem safety theorem.

No automatic aliasing is needed to obtain the everyday benefit. The trade is explicit: after admissible automatic fresh import, late history may reveal another birth or an old deletion of similar bytes. Keep the admitted work; do not retroactively claim it was never a note. Known applicable deletion/stamp evidence **before** admission still takes the specific restoration/dependency path.

## Reproduce

```sh
python3 docs/tla/check-uuid-experiments.py \
  --java /path/to/java --jar /path/to/tla2tools.jar \
  --only ExternalImport --timeout 60
```

`--only ExternalImportPolicy` selects the rule survey/decision checks; `--only ExternalImportAdmission` selects the dynamic bridge. Each run retains exact source copies, configs, logs, traces and `results.json` in its printed temporary directory. The survey additionally records every rule in `survey.json`. Expected counterexamples reject an identified claim or witness reachability; parse/runtime errors, timeouts and unrelated failures never count as success. There are no state/depth cutoffs.

The updated projection-stamp configurations remain a separate run (`check-segment-models.py --only stamp`); `--only external-file` runs the lifecycle follow-up. Adoption aligns the spec, ADR, protocol and implementation/verification plan, not every alternative survey rule. The original 60 fixtures set the new transition fields false, preserving their comparative costs; separate dynamic fixtures check prior-projection retirement and unavailable-but-accounted-for relationships.

## Completed validation

The final **97 expected outcomes** all completed: **49 exhaustive passes, 31 rejected hypotheses/negative controls, and 17 reachability witnesses**. Five passing runs check conditional temporal properties; the installation-stall and missing-history-wakeup controls produce the intended temporal counterexamples. A rejected UX hypothesis is a recorded trade-off, not necessarily a broken policy.

| Module | Exhaustive passes | Rejected hypotheses/controls | Witnesses | Largest completed graph |
| --- | --- | --- | --- | --- |
| `ExternalImportPolicyLab` | 34 | 18 | 3 | 45,056 states: 22,528 selected rules, each followed by its 60-case result vector |
| `ExternalImportAdmissionLab` | 15 | 13 | 14 | 2,089 states |

At the initial experiment completion, all 64 passing main/dependency snapshots byte-matched that source revision. The adoption follow-up adds active-transition comparisons and reruns these cases; its current results are recorded in Verification. Initial dependent-quantifier syntax errors were corrected before successful runs, not counted as counterexamples. Earlier 6,008- and 10,240-rule pilots were expanded to the completed 22,528-rule survey. No timeout or truncated search was accepted.

Retained artifacts:

- Final models/configs/logs/traces/results and policy surveys: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/notation-tla-uuid-hp1kiwnr`.
- Existing hint-priority revalidation regression: **33 expected outcomes**, `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/notation-tla-uuid-rvabbpf6`.
- Adopted projection-stamp regression: **11 expected outcomes**, `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-segment-tlc-nvq9xg70`.

The initial `./build.sh` completed with exit 0, with existing sandbox/CoreSimulator and destination diagnostics. Report-link and Python syntax checks passed. That exploratory run did not change normative policy; the later adoption does. Neither changes production app/UI code or the native probe implementation.
