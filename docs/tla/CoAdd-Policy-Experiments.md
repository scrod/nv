# Simultaneous external imports: policy experiments

2026-09-07. **Co-add remains experimental, not adopted.** These models compare refinements of the [deferred co-add sketch](../impl-proposal-5/Protocol.md#separate-text-files-and-the-identity-limit): deliberately assigning simultaneous imports to one logical note, not proving physical identity. The subsequent [separate-file policy](../iCloud-Drive-Support-Spec.md#separate-plaintext-files) and [ADR-0014](../adr/0014-distinguish-logical-deletion-projections-and-conflict-disposition.md) adopt ordinary automatic imports with targeted repair questions; **Import as New still creates a fresh birth**. Earlier blanket-review alternatives below are experimental comparisons, not current requirements.

The aim is fewer surprising duplicates, silent combinations and lost restorations. TLC tests concrete consequences, not human preferences or probabilities. The prioritization below assumes that ordinary NV sync/associated external editing are more common than ambiguous independent imports, and that erasing deliberate work is worse than a recoverable duplicate. Those are design judgments, not measured usage data.

The subsequent [external-import experiments and adoption](External-Import-Policy-Experiments.md) select narrowly targeted repair questions and tolerate late duplicates. They determine when to **ask**, without enabling identity unification. Their private latest-snapshot/frozen-input policy supersedes no co-add proof: the pending-byte abstraction below did not itself implement that storage. The advisory hint-priority conclusion is adopted separately; historical replay remains optional.

## Results in brief

| Question | Most useful refinement | Remaining trade-off |
| --- | --- | --- |
| When should imports share identity? | Preserve explicit fresh-create intent. A separate, deliberately chosen matching operation could share an identity for an exact path/occupancy/content match. | An automatic exact match still combines independently created identical files. Requiring consent costs interaction; requiring identical initial content misses shared files edited before the second import. |
| How should a filename become reusable? | Name distinct **occupancy events**, and derive a vacancy token from the causally maximal occupancy events once each is released. | This needs a precise recorded occupancy lifecycle. Local vacancy is not global vacancy; observers missing an occupancy event must not pretend their tokens agree. |
| What if deletion history arrives late? | Keep passive unclassified bytes pending; honor explicit fresh imports; preserve genuinely concurrent admitted work using the existing causal deletion distinction. | Automatically admitting ambiguous bytes can create a ghost note from stale file delivery. Pending review avoids that automatic creation but cannot also restore a hidden external restoration without a choice. |

These first three models are bounded slices, **not a composed implementation proof**. In particular, the occupancy allocator is not wired into the dynamic import/delete model. A fourth [revalidation experiment](#historical-hints-and-revalidation--coaddrevalidationlab) below compares local hint handling without making it an occupancy-event writer. A passing policy in one slice does not discharge another slice's assumptions.

## 1. Identity and user intent — `CoAddIntentLab`

Two hosts independently observe, capture, admit and durably install one import each. Publication, peer receipt and derived input-set evaluation are separate actions. A file can change between observation and admission; one host can crash and recover. `Observation` exposes only path, local occupancy token, content token, invocation mode, ambiguity classification and generation. Physical origin is **not** an algorithm input.

| Rule (`Policy`) | Benefit | Counterexample or cost |
| --- | --- | --- |
| `fresh` | Independent identities cannot accidentally combine; ordinary Create and Import as New retain their meaning. | Two imports of the same shared external file can become two notes. |
| `path` | Very simple same-name unification. | Reuses identity across different occupancies and even overrides explicit fresh-create intent. Rejected. |
| `slot` | Match path plus occupancy token, except fresh-create commands and ambiguous names. Can combine differing concurrent content as one birth with separate revisions. | Two independent files at that logical position become alternatives of one note even if users intended separate notes. |
| `exact` | Also require equal captured content. Avoids combining differing independent contents. | Independent identical templates still combine. Conversely, one shared file edited before the second import produces separate identities. |
| `consent` | Apply exact matching only to an explicit matching invocation; all other new admissions stay fresh. | Does not automatically deduplicate discovery. It requires a distinct user promise, not relabeling Import as New. |

`consent` is a hypothetical invocation, not a new approved UI control. Both participants in its matching fixture deliberately accept logical path equivalence. This does not prove physical identity, and a unilateral matching request is not modeled as consent to reassign an already established unrelated UUID. Existing positive projection association remains a separate automatic path.

The `sameFile` and `hiddenCopy` fixtures have identical observations and transitions. Only the desired outcome differs: unite the shared file; keep independently created identical files separate. Thus the tested automatic rules cannot satisfy both expectations. Adding equal content narrows the ambiguity; it does not remove it. The body participates only in the *initial* candidate birth key, not in subsequent editing identity.

Ten scenarios cover shared input, changed shared content, hidden duplication, different paths, different occupancy tokens, forced fresh imports, ordinary equal-title creation, explicit matching consent, ambiguous filename classification and a changing file. The ambiguity Boolean is a supplied classification: these tests do not implement Unicode/case-folding rules.

Assertions check distinct/unified birth outcomes, fresh-command intent, retention of **both creation-record IDs even when their content is equal**, and exact capture freshness at admission. Mutations remove the capture fence or discard one represented input. Witnesses reach joined/separate imports, recovery of an already durable import followed by peer exchange, and actual rejection followed by recapture of the changed generation. Conditional progress starts with an already durable import; it never assumes the user chooses to import.

## 2. Filename occupancy — `CoAddSlotLab`

An **occupancy event** here is one occurrence of a logical note taking a path. It is an experimental identity distinct from the note birth: renaming a note away and back creates a new occupancy event even though its note UUID stays unchanged. A **release** ends that occurrence at the path, by deletion or rename-out. Neither term adds a new production record kind yet.

The finite history contains first occupancy `O0`, independent releases `d` and `r`, return occupancy `O1` of the *same* logical note, another occupant `X`, their releases `s` and `t`, and unrelated history `u`. Hosts receive causally closed but potentially incomplete subsets. They capture local vacancy, derive a token, then admit or reject it after another local-history check. Another occupancy can arrive between capture and admission.

| Token rule | Result |
| --- | --- |
| Filename alone (`path`) | Reuses the first empty-path identity after delete/recreate. |
| Last release-operation IDs (`releaseIDs`) | Two hosts seeing independent releases of the same occupant derive different tokens: unnecessary duplicates despite agreeing which occupancy ended. |
| Whole known history (`wholeHistory`) | An unrelated operation changes the import identity. |
| Logical occupant UUID (`occupant`) | Rename away → return → rename away repeats the token: the same UUID hides a new occupancy occurrence (an ABA cycle). |
| Decline multiple releases (`singleRelease`) | Avoids unsafe admission but unnecessarily rejects redundant releases of one occupancy. |
| Maximal occupancy-event set (`episode`) | Passes the seven lifecycle scenarios plus the later rename-hint case: independent releases of one occurrence agree; later occurrences remain distinct; unrelated operations do not matter. |

The candidate algorithm is:

1. For one agreed normalized path and collection/genesis, find the causally maximal **occupancy events** in the known valid path history. The initial vacancy has a genesis marker.
2. Require applicable release evidence for **every** maximal occupant. Concurrent occupants form a set; do not pick one by arrival order or UUID order.
3. Derive a vacancy token from the path and canonical occupancy-event set, not the IDs of redundant releases or unrelated operations.
4. Capture the token and recheck local vacancy/occupancy evidence at admission. Changed evidence rejects the attempt. A final physical-file operation still needs its own file/root checks.

This is an algorithm candidate over a supplied valid event history. The model implements the exact finite relationships, not a general DAG traversal. In particular, an admitted claim does not itself emit the next modeled occupancy. Claim → recorded occupancy → rename/delete → next claim remains a required composition test. Delete reuse and rename reuse intentionally share the same vacancy graph; this does **not** prove they have the same note-deletion or filesystem effects.

Two further mutations catch accepting a stale captured vacancy and checking only one of two concurrent occupants. Witnesses reach redundant-release agreement, distinct ABA tokens, independence from unrelated history, rejection on newly disclosed occupancy, rename reuse and vacancy after *both* concurrent occupants have been released.

The subtle limit: a host can legitimately derive the initial token while another already knows an undisclosed occupancy. The test permits this. Its claim is about *matching justified local knowledge*, never an exclusive global slot or permission to overwrite/unlink anything. Different tokens remain separate; later knowledge must not silently rekey already admitted work.

## 3. Late history, deletion and restoration — `CoAddLateHistoryLab`

This model connects candidate identity handling to the spec's [causal deletion rules](../iCloud-Drive-Support-Spec.md#causal-values-conflicts-and-deletion). It dynamically records an old creation `a`, Delete `d`, independently captured file `b`, an optional subsequent edit `e`, and an explicit fresh copy `f`. Each host has durable records, applied knowledge and parked incoming records; a provider set transports records independently. Delete captures what its author actually knew. Receipt cannot apply a child before its dependencies. One host may crash and reconstruct from its retained records.

| Rule | Useful result | Failure/cost |
| --- | --- | --- |
| Delete everything assigned the old birth (`birthDelete`) | Suppresses a stale-file echo. | Also hides an unobserved genuine import/restoration or edit. Retaining bytes in history is not equivalent to preserving required live concurrent work. |
| Same birth plus causal preservation (`causal`) | Old birth stays deleted; an uncovered import/edit survives separately. An explicitly fresh import survives the old Delete. | A stale file automatically admitted as a new concurrent operation can now appear as a conflict note. Causality cannot infer that it was merely old bytes. |
| Always fresh (`fresh`) | Keeps independently imported work out of the old birth's Delete scope. | Passive stale file delivery can create a new ordinary note. |
| Pending review for passive discovery (`review`) | Unclassified bytes stay pending rather than appearing as a normal/conflict note. An explicit fresh choice preserves them without reusing the deleted birth. | A real external restoration with no distinguishing evidence requires interaction too. |
| Equal payload implies observed (`equalMeansObserved`) | Attempts to suppress a duplicate without recording its operation. | Incorrectly treats an unseen operation as covered by Delete. Equality is not causal acknowledgment. Rejected. |
| Revive the old birth (`revive`) | Attempts to retain imports in place. | Violates durable deletion. Rejected. |

Six scenarios distinguish stale echo, observationally identical hidden restoration, explicit restoration before old deletion is disclosed, explicit import after deletion is known, deletion that observes the import, and a later edit that the Delete did not observe. The last case checks the important chain: `b → e`, while Delete observes `b` but not `e`. Preserve `e`, not a second obsolete copy of `b`.

In `review`, `b` denotes **private preserved pending bytes**, not a new synced creation. Only the explicit fresh choice `f` becomes a public operation, carrying its full captured value; it has no dependency on private `b`. This abstraction imposes a real implementation obligation: if pending preservation is promised to survive a crash, those bytes and their review state need durable local storage. Merely leaving an externally changeable file in place is not that guarantee. No pending-byte codec or new storage location is adopted by this experiment.

The first run exposed an assertion mistake: after `f` preserved the selected bytes, the invariant still demanded that `b` remain pending. The corrected assertion follows the explicit copy's provenance and actual captured-value token. A wrong-copy mutation now fails that assertion. It does **not** count an arbitrary equal-content note as causal coverage.

A second overbroad hypothesis demanded automatic restoration even when a subsequent Delete had already observed that import. The refined expectation protects an *uncovered* import; a separate witness establishes that an observed import really is suppressed. This preserves the spec's intentional deletion semantics instead of weakening Delete to satisfy a restoration hypothesis.

Safety checks cover old-birth absence, fresh-choice survival, uncovered import/edit preservation, observed-import suppression, no payload-equality acknowledgment, private pending/copy preservation and recovery of durable history. A restart mutation drops an installed import and must fail. Witnesses reach post-crash conflict preservation, post-crash fresh recovery, the uncovered edit, child-before-parent parking, explicit resolution of pending bytes, known-Delete/fresh import and observed-import deletion. Conditional progress applies only to public durable records with eventual transport/application/recovery; no user choice or provider deadline is assumed.

`staleEcho` and `hiddenRestore` again expose the same observations. The experiments cannot simultaneously promise **no automatic ghost** and **automatic recovery of every hidden restoration**. This is a tested ambiguity in the inputs, not a claim that Apple violated a contract.

## Least-surprise direction to investigate next

1. Leave ordinary NV sync and positively associated external edits automatic; those already have provenance and are outside this ambiguous-import experiment.
2. Keep Create, Import as New and explicit restoration irrevocably fresh. Late evidence must not turn those commands into an implicit association or old-birth resurrection.
3. For ambiguous passive discoveries, retain the current pending-file choice. If duplicate manual imports prove a common pain, test a **separately consented exact-match import**. Do not change Import as New's promise. A more aggressive path-slot-only option should explicitly disclose that differing imports can become alternatives of one note.
4. If that feature is desired, develop the occupancy-*event* rule rather than hashing release IDs, whole history or note UUIDs. A local token is not proof of global vacancy.
5. Once work has been admitted under a chosen identity, use causal deletion/preservation. Do not retroactively downgrade acknowledged edits to “probably stale,” silently alias established UUIDs, or let the identity decision authorize file removal.

This ordering prioritizes familiar automatic workflows and explicit user intent. It accepts prompts for uncertain provenance and occasional separate identities when knowledge differs. The more automatic `slot`/`exact` candidates trade those prompts/duplicates for false combination and ghost-note risk. Which risk users prefer remains a product choice; the tests do not select a statistically optimal policy.

Before adoption: compose dynamic claims with recorded occupancy/release history; define concurrent move/rename and multi-path ownership; freeze normalization, creation-kind/domain and token encodings; specify consent and later explicit reconciliation without hidden UUID reassignment; integrate actual pending-byte durability, segment barriers, projection/root fences and exact-file saves. General history, arbitrary replicas, repeated crashes, undo of occupancy-changing operations and GC are not covered by these finite fixtures. No new sidecar, xattr or provider API is assumed. The [existing Apple probes](../Apple-API-Contract-Validation.md) already require conservative handling of copied/stripped metadata and delayed independent delivery. The additional FSEvents investigation below tests a possible source of local hints, not a solution to the information gaps above.

## Historical FSEvents follow-up

### Contract and useful scope

Historical events can help find paths that need reinspection after NV was not running. Use a per-device stream and its **FSEvents database UUID**, not just a device number or a filename. A changed/unavailable database UUID, wrapped IDs, dropped/coalesced events or changed root defeats incremental replay assumptions; rescan. Apple's guide recommends treating the event list as advisory and combining it with fresh snapshots. This is local volume history, not the remote Mac's logical operation stream. [Apple's persistent-event guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).

The installed macOS SDK's `CoreServices/FSEvents.h` is more explicit: the `FSEventStreamEventFlags` discussion says not to reconstruct filesystem state by replaying these hints. `ItemRenamed` supplies no source/destination transaction pair. `UseExtendedData` supplies an inode `fileID` where available; `FSEventStreamCreateWithDocID` requests document IDs too. Neither turns a past path into a present object reference. Foundation specifically warns against persisting `fileIdentifier`, while allowing it to correlate an enumerated URL with an FSEvents path. [Apple's fileIdentifier contract](https://developer.apple.com/documentation/foundation/urlresourcevalues/fileidentifier).

Two easily overlooked details are explicit in that SDK header:

- `FullHistory` returns the overlapping first stored chunk, including event IDs at/below the requested cursor, to avoid skips near an unclean restart. It is not a promise of complete operation history.
- `MarkSelf` and `IgnoreSelf` do not classify/filter historical events. Historical replay cannot identify an earlier NV process's deletion intent from `OwnEvent`. `HistoryDone` ends historical delivery; its path is ignored, and it says nothing about undisclosed remote provider work.

These declarations were checked in the Xcode macOS SDK used to compile the probe, alongside the [FSEvents API reference](https://developer.apple.com/documentation/coreservices/file_system_events). None of the findings below is treated as an Apple contract violation.

### Compiled observations

[`FSEventsHistoryProbe.m`](../../tests/FSEventsHistoryProbe.m) creates a fresh synthetic tree, records a per-device cursor/database UUID, performs known operations with before/after `lstat` snapshots, and launches a **new process** to replay from that cursor. It requests file events, extended data, document IDs, FullHistory and MarkSelf. No raw `.fseventsd` parsing, privileged event source, log purge, production NV state or GUI automation is involved.

Completed on macOS 26.6.2 and the Intel Mini's macOS 14.8.9 under local `/private/tmp`, plus a local macOS 26 run inside the designated iCloud `API_Contract_Testing` folder. All reached `HistoryDone`. These are **local filesystem/replay observations on two OS versions**, not a cross-Mac cloud-delivery test or a reboot/power-loss test.

| Known fixture operation | Observed result | Implication |
| --- | --- | --- |
| `A → B` | Old/new path hints could be correlated with the same local inode. | Useful candidate discovery, subject to current validation. |
| Rename `Return` outside the watched tree and back | One `Return` path record with `ItemRenamed`, rather than two reconstructible moves. | Renamed does not mean the path is now vacant or identify how many occupancies elapsed. |
| POSIX staged replacement of `Safe` | Two inode values appeared for the same path, both with rename hints. | Do not pair path flags into an unambiguous logical rename or substitute historical IDs for the current snapshot. This probes an external writer's replacement, not NV's coordinated Foundation algorithm. |
| Copy, then rename the copy | Copy/clone hints and a distinct destination inode; a clone-related row could also name the source inode at the copy path. | Inspect the actual current candidate, not a generic “last ID for path” map. |
| Hard-link, then rename that link | `B` and `HardMoved` simultaneously had the same inode and link count 2. | Equal inode is not unique directory-entry or logical-note identity. |
| Unlink/recreate `Reuse` | Old/new inode values and combined create/remove/modify flags in historical rows. | Same path must not inherit deletion authority; the hint stream is not a generation counter. |
| Replay with `FullHistory` | Overlap included the unchanged file's pre-cursor creation; returned IDs were not globally sorted. Historical rows lacked OwnEvent even though the probe authored the operations. | Process hints idempotently, not as ordered user commands. Do not use callback order or a historical self/nonself guess to encode intent. |

In the iCloud folder, document IDs could arrive after the initial file events. An earlier exploratory run also observed document-ID continuity across replacement and unlink/recreation; this is **not** a file-incarnation guarantee. The repeat run began before those IDs had been assigned. The raw records preserve this distinction instead of converting an optional metadata timing observation into a required outcome.

The probe initially needed two harness corrections: Foundation's path normalization obscured the `/private` spelling needed for a verified Data-volume-relative path, and a SinceNow stream was incorrectly labeled historical while waiting for a sentinel it never requests. It now uses `realpath` plus a verified mount-relative spelling and labels SinceNow as live immediately. The repeated results below use the corrected labeling. Historical replay refuses an unavailable/changed database UUID and validates the fixture root; these guards do not purport to implement production root continuity.

### Consequences for the candidate rules

The slot model adds four checks: a passing `renameHintOnly` scenario, its deferral witness, and failures for `eventRelease` (treat a raw rename hint as a committed release) and `localEvents` (derive shared identity from observer-local event IDs). The latter intentionally qualifies IDs by observer; omitting that namespace would introduce collisions rather than solve disagreement. These are narrow policy checks, **not** a full FSEvents replay/cursor model.

The defensible integration is a **discardable candidate/invalidation cache**: use event paths and current-volume IDs to prioritize rooted reinspection, then let existing unique applicable association, history and current-catalog checks decide. A rename hint may warn that a supposedly unchanged occupancy needs rechecking; lack of that hint cannot prove continuity or newness. A replay gap falls back to scanning and the pending-file choice, without holding ordinary editing hostage. This fits the current “events wake reconciliation” contract; it does not require changing UUID rules.

If implemented later, keep `{event-database UUID, cursor, root scope}` with private local scanning state. The referenced baseline/association must already be valid; the cursor is neither that baseline nor a durable note operation. Never sync the cursor or derive a portable occupancy token from it. Root movement requires re-resolving/rebinding the watched path. A physical volume carries its event database when moved, but copying a collection through iCloud does not share that database.

**Recommendation:** do not add historical replay as a prerequisite or a new correctness authority for co-add. It may improve local rename discovery or diagnostics, but it cannot distinguish intentional remote deletion, hidden external restoration or two independent identical imports. Measure a missed-rename/prompt problem before adding the private replay machinery; current catalog reconciliation remains the fallback.

Build and run:

```sh
make -C tests /tmp/notation-integration-tests/FSEventsHistoryProbe
/tmp/notation-integration-tests/FSEventsHistoryProbe run /private/tmp
# Optional: use the explicitly designated provider testing directory as PARENT.
# Replay a retained fixture in another fresh process:
/tmp/notation-integration-tests/FSEventsHistoryProbe replay /path/to/nv-fsevents-history-XXXXXX
```

The probe retains `manifest.plist`, `observations.jsonl` and synthetic files. Exit 0 means the fixture ran and historical completion was observed, **not** that every syscall produced a distinct event. Exit 3 is unavailable/inconclusive replay; exit 1 is a setup/fixture failure. Final corrected-labeling fixture paths:

- macOS 26 local: `/private/tmp/nv-fsevents-history-Cupwzd`.
- macOS 14 local, on the Mini: `/private/tmp/nv-fsevents-history-52521R`.
- macOS 26 local iCloud folder: `/Users/scrod/Library/Mobile Documents/com~apple~CloudDocs/API_Contract_Testing/nv-fsevents-history-B2EL3K`.

The Mini log also has a local copy at `/private/tmp/nv-fsevents-remote-results.LhuSkr/mini-observations.jsonl`. The earlier iCloud document-ID observation is in `nv-fsevents-history-T4Gb63` under that testing directory; its `stage=live` output predates the labeling correction. No normal note file was removed. No total event-log loss, inode recycling, unmaterialized-body lifecycle, remote-arrival mapping or historical retention duration was induced by this probe.

## Historical hints and revalidation — `CoAddRevalidationLab`

### Question and abstraction

Does historical FSEvents evidence improve classification or useful work ordering, and what does it cost when a safe save, return rename or delayed notification looks suspicious? [`CoAddRevalidationLab.tla`](CoAddRevalidationLab.tla) and its [default configuration](CoAddRevalidationLab.cfg) compare four implementations of one bounded reconciliation pass. This is a **new model experiment using the already measured hint shapes above**, not another native probe run or a new Apple guarantee.

The scope is one already identified birth and two potentially related entries, `P` and `Q`, on two hosts. A unique applicable represented-state match can associate the observed value under the current projection policy. This is not arbitrary UUID unification, permanent physical identity, or an automatic import of an unclassified file. The two entries form the candidate's complete relevant inspection frame; this does **not** prescribe reading all note bodies at startup.

| State | Meaning and boundary |
| --- | --- |
| `history[h]` | A valid finite chain of accepted revisions/occupancy evidence, initially `{0}` or `{0,1}`. Revision 1, when present, supersedes revision 0. Receipt can occur between capture and publication. Dependency closure and its local durability are input obligations. |
| `version[h]`, `root[h]` | Independent exact-file/catalog and root-scope fences. One disclosed file or root change can occur on host 1. They abstract the existing validation boundary, **not** Apple counters detecting every invisible physical ABA. |
| `hint[h]` | Locally delivered advisory batch count. Delivery is optional, can differ between hosts and can occur between any active steps. Normally one batch; the storm fixture permits three on host 1 for unchanged current bytes. A gap is rescan evidence, not a path or occupancy event. |
| `frame[h]`, `read[h]`, `bytes[h]` | Captured scope, inspected entries and separately read values. The finite matcher checks known revision, path, exact payload, stamp applicability and duplicate candidates; no hidden physical-origin oracle is available. Local inode values are exposed but do not authorize association. |
| `phase[h]`, `attempts[h]` | Capture → individual inspections → prepare → publish or reject/recapture. Two attempts bound a pass. An associated value, review, missing-history wait or exhausted pass ends this invocation; neither waiting nor exhaustion means the entire UI is blocked. |
| `result[h]`, `token[h]` | Published classification and its episode from captured accepted history. Hint delivery cannot itself author a new shared episode. |

`Read` observes current fixture bytes, not a value silently frozen at capture. `Commit` separately checks file, root and history scope. Thus the negative controls can publish a genuinely stale prepared decision when a fence is removed. Hint delivery and history receipt can also occur between those steps. Each frame is inspected afresh after rejection; the hint counter is not retained note identity.

### Compared rules and results

| Rule | Result and interpretation |
| --- | --- |
| `scan` | Inspect `P`, then `Q`, using full scope and normal fences. Safe baseline, not a claim about production scan order. All stable classified projections finish in one attempt. |
| `historyFirst` | Inspect the path named by already accepted history first. Reaches the known renamed projection first **without FSEvents**; the same safety and stable one-pass result holds. |
| `priority` | Use an available hint to choose inspection order; retain complete inspection and the ordinary file/root/history fences. Same safety and stable one-pass result, including delayed hint storms. A hint can bring a file naming missing history to attention first when the current history does not yet name that path. |
| `hinted` | Also reject whenever a new advisory batch arrives after capture. One false alarm can recapture successfully, but repeated late batches can exhaust both attempts despite unchanged valid files/history. Safe classification does not imply good UX or useful completion. |

The read-order witnesses establish order, **not measured latency, fewer total inspections or earlier safe publication**. `historyFirst` deliberately prevents crediting FSEvents for an optimization already available from history. Earlier missing-dependency discovery could permit earlier fetching in an implementation; this model does not schedule that fetch or prove its latency benefit.

Thirteen fixtures cover safe replacement, known rename, asymmetric hints, physical rename-away/return without an accepted intermediate logical transition, changed-content reuse, copied-stamp ambiguity, replay gap, file/root/history races, missing history, stale stamp and a delayed-hint storm. `roundTrip` does not manufacture a logical release from a physical rename hint. `historyRace`, in contrast, supplies an actual accepted later occupancy at the same path: its episode changes through history, not events. These are controlled finite inputs, not a reconstruction algorithm for arbitrary rename histories.

Negative controls reject: keeping a candidate invalid forever after a hint; deriving a portable episode from host-local event state; trusting no-event silence; treating a hint as association proof; inspecting only hinted paths; omitting file, root or history fences; ignoring a duplicate, exact body or contradictory stamp. A separate mutation disables successful publication and fails the progress check, ensuring that merely refusing all work is not an acceptable positive result.

Safety assertions require complete relevant inspection, applicable represented state, duplicate rejection, exact publication fences, and equal episode results for equal accepted histories across hosts. Separate UX checks require stable valid projections to be accepted and test whether extra attempts occur. Negated `Never…` assertions witness actual acceptance, asymmetric agreement, retry after each changed scope, false-alarm recovery/exhaustion, review, missing-history parking and later-episode acceptance.

The temporal assertion assumes weak fairness only for local inspection/decision work. It establishes that a bounded pass terminates, possibly pending or exhausted. It assumes neither that hints/history arrive nor that a user chooses anything. No claim is made that two attempts suffice for arbitrarily frequent real changes, that a blocked native accessor returns, or that parking finishes synchronization.

### Corrections exposed by the checks

An early later-episode witness was unreachable because its fixture still carried a stamp naming the **old** revision. Deferring was correct; accepting solely because the body matched the new history would have contradicted the intended stamp check. The `staleStamp` scenario retains that review case, while the corrected unstamped `historyRace` fixture exercises the permitted unique descriptor match and actual scope-retry transition. Removing stamp validation now has its own counterexample. A separate initial heterogeneous token encoding caused a TLC type-evaluation error and was replaced with consistently typed symbolic tokens; neither parser/runtime errors nor unreachable witnesses were counted as passes.

### Recommendation and remaining limits

**Use hints for scheduling and invalidating a cached candidate, not as a second identity authority or an unconditional veto after a complete fresh validation.** In these fixtures the fully validated scan already obtains the correct supported classification. Hint prioritization preserves that result; restarting on every advisory batch adds work and can leave a healthy candidate unnecessarily pending. A real current file/root/history mismatch must still reject the prepared decision. This does not justify ignoring events when the current inspection is incomplete, cached, out of scope or otherwise unable to validate what changed.

The strongest demonstrated benefit is candidate ordering, especially when a file references history not yet known. The experiment does **not** establish greater physical-episode accuracy than a complete validated scan. It therefore does not justify adding historical replay as a correctness prerequisite. Missing/gapped replay takes the ordinary complete-inspection path; explicit user choices and the existing pending-file policy remain available.

The module does not emit occupancy/release records, admit co-add claims, perform filesystem writes/deletions, model crash durability or compose with the other co-add models. A same-path copied projection with identical valid evidence remains an identity limit, not a solved case. No arbitrary DAG, repeated physical ABA, hidden remote intent, event retention guarantee, wall-clock performance or actual UI behavior is proved. No production policy or new private-state format is adopted.

## Running and interpreting the checks

```sh
python3 docs/tla/check-uuid-experiments.py \
  --java /path/to/java --jar /path/to/tla2tools.jar --only CoAdd --timeout 60
```

Each module has a small default `.cfg`; the shared runner generates the full hypothesis matrix. Use `--only CoAddIntent`, `--only CoAddSlot`, `--only CoAddLate` or `--only CoAddRevalidation` to isolate a slice. Positive runs must exhaust their finite graphs; expected counterexamples must violate the designated assertion. `Never…` assertions are deliberately negated reachability goals, not rejected safety policies. Broken-rule controls and undesirable UX hypotheses are labeled separately in the tables above. Parser failures, timeouts and other invariant failures never count as success.

Two hosts, at most two imports, a fixed small occupancy DAG, at most five late-history records and one crash keep the checks bounded. No state/depth constraints or sampling substitute for exhaustion. Safety allows unlimited provider stuttering. Three temporal runs add weak fairness only for recovery and transport/evaluation of already durable public records, not admission, UI approval or all-cloud disclosure. Complete local installation is abstract in these models; [ImmutableSegmentDurabilitySafety](ImmutableSegmentDurabilitySafety.tla) tests its separate filesystem-ordering obligation. [ProjectionStampSafety](ProjectionStampSafety.tla) covers the adopted stamped-projection decision boundary; [SegmentDeletionSafety](SegmentDeletionSafety.tla) and [SegmentDeletionOrderingSafety](SegmentDeletionOrderingSafety.tla) cover adjacent deletion rules. These links do not constitute formal composition.

### Executed results

All **245 expected outcomes** verified with TLC 2.19 and the Wolfram-bundled Java runtime: **170 exhaustive passes, 41 rejected-policy/broken-rule counterexamples, 34 reachability witnesses**. This includes a fresh rerun of the original 112 checks and all 133 revalidation checks (102 exhaustive passes, 15 rejected hypotheses/mutations, 16 witnesses). The 24 passing conditional temporal checks are included in the exhaustive passes; disabling revalidation publication supplies one additional expected temporal failure. No timeout or cutoff was accepted.

| Model | Exhaustive passes | Rejected hypotheses / broken controls | Witnesses | Largest positive graph |
| --- | ---: | ---: | ---: | ---: |
| `CoAddIntentLab` | 43 | 9 | 4 | 1,525 distinct states |
| `CoAddSlotLab` | 9 | 9 | 7 | 17,052 distinct states |
| `CoAddLateHistoryLab` | 16 | 8 | 7 | 817 distinct states |
| `CoAddRevalidationLab` | 102 | 15 | 16 | 7,096 distinct states |

Final 245-case matrix configurations, model copies, logs, traces and `results.json`: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/notation-tla-uuid-tsdf6b1r`. The original 112-case artifacts remain at `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/notation-tla-uuid-im_ub_hf`. The adjacent adopted projection-stamp suite was also rerun: all 11 expected outcomes verified at `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-segment-tlc-gseznjqa`. These runs do not enable co-add or strengthen Apple's documented contracts.

The app build script also completed with exit 0; its existing sandbox/CoreSimulator and destination warnings are recorded in `/tmp/nv-fsevents-revalidation-build.yIDXnG`. No app implementation or native probe source changed in this follow-up.
