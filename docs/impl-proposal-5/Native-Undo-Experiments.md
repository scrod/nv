# Native undo and retained history: experiments

Investigation for [proposal 5](README.md), 2026-09-05. This is measured evidence and a candidate integration strategy, not a replacement for the adopted [undo contract](Implementation.md#persistent-meaningful-action-undo). No production editing, saving or undo code was changed.

2026-09-09 policy clarification: follow Apple's text-editing contracts/HIG and NV's existing scheduling before designing new input policy. The separate committed snapshot, input-depth tracking and peer-refusal adapter below are tested candidates, not required production mechanisms or evidence that normal input-method focus transfer fails. The composition model likewise checks that chosen adapter, not a universal ban on provisional text in crash recovery. First investigate correctly registered external undo edits; the coarse post-remote fallback remains unaccepted. See [platform boundary and next experiments](../Apple-API-Contract-Validation.md#text-input-and-undo-platform-boundary).

Subsequent policy decision: [invocation-scoped Undo/Redo review](Implementation.md#invocation-scoped-undoredo-review) now explicitly completes the original command and preserves its existing redo sequence. Independent Note History recovery and conflict-badge choices retain new-action semantics. The dedicated [`ReviewedUndoSafety`](../tla/ReviewedUndoSafety.tla) check and [verification record](Verification.md) cover that decision separately; it does not retroactively turn these platform probes into a production UI/codec proof.

Portable causal policy is also now adopted: durable eligibility derives from validated `ActionRecordV1` scope-parent and compensation edges across every origin, so a unique remote-origin candidate can be undone on another Mac. Native AppKit groups remain local; the shared router must also verify causal eligibility before consumption. Valid native ranges alone do not establish which action should be undone. The queues in `UndoHistoryHandoffSafety` model native/index handoff on one already-selected causal branch; [`PortableCausalUndoSafety`](../tla/PortableCausalUndoSafety.tla) owns multi-origin candidate ordering, concurrent review and private-state rebuild. These AppKit observations do not supply that repository decoder or persistence proof.

## Conclusion

Meaningful saved-action undo can plausibly continue through Command-Z across launches without serializing AppKit's private undo objects. Fine-grained native undo can coexist with that history **while its original text state remains valid**. Neither passive undo-group observation nor retaining old native range operations across arbitrary remote text replacement supplies the missing integration automatically.

The smallest promising boundary is a **saved span** (a saved-edit group), which can contain several native undo groups. Track its actual remaining effect after native undo; do not discover/serialize every internal typing group. Reuse NV's 2.7-second idle / 15-second non-resetting maximum-delay scheduling targets and forced lifecycle boundaries; group notifications are not the scheduling clock or a durability guarantee. Switching to saved-action granularity after a remote body update is a candidate UX compromise, not a silently adopted policy.

## What ran

[`NativeUndoProbe.m`](../../tests/NativeUndoProbe.m) is a standalone MRC Cocoa executable using an explicitly constructed TextKit 1 text view, its own undo manager/window and synthetic text. The [stdlib runner](../../tools/run-native-undo-probes.py) isolates each of 31 automated scenarios in a process with a 20-second timeout and retains JSON events, checks, observations and stderr. It performs no note, provider or segment I/O. Paste uses a unique private pasteboard, not the user's clipboard. Capture commands only exercise an undo boundary; they do not save anything.

All named checks completed on Apple Silicon macOS **26.6.2 (25G83)** and Intel macOS **14.8.9 (23J631)**. The three metadata scenarios report that the macOS-15 action-user-info API is unavailable on 14; their ordinary typing checks passing is not coverage of that API there. Other recorded observations agree between these two systems. Neither run establishes behavior on macOS 11.5–13, 15, or every future release.

An initial sandboxed paste run failed because the pasteboard service was inaccessible. Running outside that execution sandbox passed. The probe was corrected to stop after the prerequisite failure rather than also attempt a subsequent invalid range access. This was not an Apple contract violation. No Automation, Input Monitoring, Accessibility or Apple Events permission was needed for these own-window experiments.

The user also physically typed `alpha`, Undo, Redo, Cmd-S, `beta`, Undo, Redo, Return, then closed the interactive window. The trace confirms `"" → alpha`, capture at grouping level zero, then `alphabeta → alpha → alphabeta` on the second undo/redo pair. No input method was used. The recorded trace contains no newline insertion, so it does **not** establish the reported Return's text-input path. The automated `setMarkedText:` tests below remain programmatic composition evidence only. The interactive runner's successful exit means it completed without an exception, not that an empty assertion list proved keyboard behavior.

## Hypotheses tested

| Experiment | Observation | Consequence |
| --- | --- | --- |
| Type A, B, C over separate run-loop turns | One undo removes ABC; coalescing outlives individual event groups | A group-close notification is not a stable, complete user-action identity |
| Observe/capture after every letter without changing grouping | Still one undo removes ABC | Passive snapshots can lie inside one later native undo; coverage cannot assume one capture = one undo |
| Break typing coalescing at each capture, with the outer group closed between edits | Undo gives AB, A, empty | A deliberate save boundary can separate subsequent typing |
| A, break/capture, B inside the same open event group | Capture sees level 1; one undo still removes AB | `breakUndoCoalescing` alone is not an outer-group boundary; defer semantic closure until safe or explicitly account for a crossing group |
| Register a callback marker after the first letter / after every letter | Changes grouping: A then empty / AB then A then empty | Instrumentation is not necessarily passive |
| Register one marker before the first mutation of a span | Typing can still coalesce; undo/redo calls the marker at the span boundary | Promising way to demarcate saved spans, not proof for every mutation path |
| Register a new marker when the delegate sees `!isCoalescingUndo` | Selection and formatting cases have two native undos but only one marker | Reject that heuristic as a complete native-group identity map |
| Set action user info once before/after the first letter (macOS 26) | One typing undo, metadata available | Useful modern decoration; cannot be the macOS-11.5 correctness primitive |
| Rewrite that metadata after every letter | Undo bodies AB, AB, empty, including a no-body-change step | Do not use repeated metadata updates as passive observation of coalesced typing |
| Saved-span partial undo/redo, format-first span, then a new branch after partial undo | Exact remaining text/attributes and span callbacks survive the exercised sequences | Supports span accounting without a marker for every native group |
| Private paste, underline, moved selection/backspace, explicit replacement | Concrete undo/redo checks pass | These public paths are exercised, not NV's transformations or the system autocorrect engine |
| Programmatic marked n → ni → committed 你 | Marked state detectable; transient draft appears in the text storage; one undo restores committed baseline | A visible body snapshot is not necessarily committed text |
| Register a guarded action; reject inside its undo callback | Value unchanged, but both undo/redo entries gone | Admission must happen before asking the manager to execute/pop the entry |
| Reject before calling undo | Value and undo entry retained | Supports the existing no-stack-change-on-refusal contract |
| Nested command grouping | Inner close leaves grouping level 1; undo executes the whole outer group | Never treat every close notification as a complete named command |
| New typing after undo | Native redo is cleared | Branching must also update the saved scope's redo eligibility, without erasing history |

Apple describes [undo notifications](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/UndoNotifications.html) as synchronization points for registration, not application persistence barriers. Apple explicitly recommends [breaking typing coalescence when saving](https://developer.apple.com/documentation/appkit/nstextview/breakundocoalescing%28%29). [Action user info](https://developer.apple.com/documentation/foundation/undomanager/setactionuserinfovalue%28_%3Aforkey%3A%29) is associated with registering actions. The experiments concern the consequences of particular call sequences; none establishes a violation of these contracts.

## Worked span accounting

`span-partial-undo` inserts a marker before the first mutation of each span and closes captures outside open groups. Deliberate native breaks make A/B and C/D distinct native units:

| Step | Live body | Remaining saved effect | Boundary callback |
| --- | --- | --- | --- |
| Capture S1 | AB | S1: empty → AB | — |
| Capture S2 | ABCD | S2: AB → ABCD | — |
| Native Undo D | ABC | S2: AB → ABC | None; S2 is only partially undone |
| Native Undo C | AB | S2 has no remaining effect | S2 |
| Native Undo B | A | S1: empty → A | None |
| Native Undo A | empty | S1 has no remaining effect | S1 |

Redo reverses those four native units. If the app durably captures the first partial undo and crashes, reconstructed **Undo Saved Edit** for S2 must remove C, not claim the whole S2 was undone already. Redo of that reconstructed compensation restores C, **not D**. D still exists in retained history, but is not the remaining effect of that undo entry. The extended [history reference check](check-history-rules.py) exercises these exact values and preserves a remote title.

If the user instead types X after undoing D, the new action branches from ABC. `span-branch` confirms Undo X returns to ABC, then Undo C returns to AB; the older partial span remains undoable even though D's native redo was discarded. `span-format` separately confirms a marker before a format-first mutation and undo/redo of attributes across a subsequent typing span. These are useful concrete cases, not a generic attributed-string coverage algorithm.

## Remote changes: the important limit

The concrete example starts with `cat`, locally inserts `!`, then inserts remote `big ` without undo registration. All three tested replacement paths—direct text-storage mutation, a should-change/did-change pair with registration disabled, and `setString:`—retain an available native undo. Executing it produces **`bigcat!`**, not `big cat`: the old inverse acts on its old range. Notification delivery does not make an untracked edit participate in AppKit's undo history. This is an unsafe application call sequence, not a promised rebase feature failing.

A remote title-only change that leaves text storage unchanged allows native undo to produce `cat` correctly. Do not invalidate unaffected notes or reconstruct a body merely because unrelated metadata changed.

Guarded history compensation is different: it works from before/after/current values and the adopted merge policy. For example, undoing a last-line edit in `top\nkeep\ncat!\n` can preserve a remote first-line edit and rename. An overlapping rewrite requires review without moving the logical cursor. **The single-line `big cat!` example itself requires review under proposal 5's conservative LF kernel.** The finite model's `prefix` region represents independent eligible regions, not a new character-level merge algorithm. A remote Delete does not authorize reviving the same birth; the existing explicit restore path uses a fresh birth. Unresolved alternatives must remain untouched by ordinary compensation of Current.

## Smallest candidate integration

1. **Separate semantic grouping from durability scheduling.** Observe outer-group closure and named-command boundaries; retain idle/max-delay capture and lifecycle triggers. At a save-span boundary, break typing coalescence and freeze immutable note/action values only at a safe command boundary. A group left open by application code is not permission to block the main thread, force-close someone else's group, or claim unsaved data durable. One native group crossing existing captures still requires the protocol's multi-capture coverage accounting; these probes do not waive that requirement.
2. **Use transient span bookkeeping, not archived invocations.** Per note/undo scope retain a native text-state epoch, active saved-span ID, its immutable before state and actual remaining after state, ordered completed span/action references, and a marker pending before the span's first undoable mutation. At `DidUndo`/`DidRedo`, combine the crossed markers with actual before/after values; record partial remaining effects. A marker alone is not evidence of which fields changed. Formatting-only edits require attributed/format values, not just string equality. Named/bulk actions retain their explicit one-owner grouping.
3. **Keep native units while valid; hand off once.** Native callbacks and reconstructed saved-action adapters must not both own the same remaining effect. Before replacing an affected body with a remote reduction, capture pending local text/coverage and establish a fence; invalidate only that body's native range epoch. Candidate fallback: its remaining saved spans become guarded logical actions, while new typing starts a fresh native epoch. Index loading inserts old eligible entries below newly admitted local actions, never replaces the whole stack. A title-only update or a conflict-view swap need not invalidate the body epoch.
4. **Preflight before execution, revalidate before admission.** Route menu/keyboard undo through the shared admission predicate. Prepare all affected values and verify scope position, birth, current generations and applicable evidence before executing a native command or admitting a logical compensation. A remote arrival between preparation and publication rejects the whole candidate. Refusal leaves positions intact; review/recovery is explicit. Do not try to cancel a stale action from inside an already executing undo callback.
5. **Persist actual effects and positions together.** Use the existing complete action/operation segment, not a separate undo log. A partial native compensation captures its remaining-effect update with the exact new note value; stale completions cannot clear later edits. Durable acknowledgment still requires the segment/parent barrier. If local persistence fails after admission, preserve pending text and use existing admission suspension; provider failure alone does not block undo or saving.
6. **Preserve AppKit composition.** The tested adapter keeps a separate last-completed-input snapshot and prevents its captures from including provisional text. That is one candidate, not a required storage protocol. Prefer normal input-context handling for local focus/close/note-switch actions and defer remote body application until a safe input boundary, then revalidate/reconcile. Do not interrupt composition merely to save or create a conflict because composition is active. Actual input methods and normal event delivery must establish whether any extra adapter is needed; injected peer calls are not that evidence.

The new persistent data is already described by action records/remaining-effect references; this experiment requires no provider sidecar or additional synced undo store. The native epoch/markers are host-process bookkeeping. The source's existing [`_undoManagerDidChange:`](../../NoteObject.m) only dirties the note, and `applyPreparedFileStateFromNote:` clears native undo. Both need deliberate segment-mode adaptation; neither is replaced by these probes.

An alternative is to own every reversible text operation and its transformation through remote edits. That may preserve finer granularity after remote updates, but entails attributed text, selection, composition, formatting, command grouping and concurrent-edit transformation—not merely an `NSUndoManager` adapter. The evidence does not justify that expansion yet. The cheaper fallback, if span integration fails a real path, is to expose saved history through Note History and retain normal native undo only in its valid session; that would require revisiting the currently required cross-launch Command-Z feature with the user.

## Bounded rule validation

Two new modules complement, rather than import/refine, the existing segment installer, action recovery and merge models:

| Model | State and boundary | Checked behavior |
| --- | --- | --- |
| [`NativeUndoSpanSafety`](../tla/NativeUndoSpanSafety.tla) | Two saved spans, four prefix-valued sub-actions, at most six native undo/redo admissions, interleaved capture/write/install/completion, one crash/recover; native commands stop at crash | Actual remaining-effect coverage; durable note/coverage agreement; partial recovery; stale-completion pending protection; conditional local settlement |
| [`UndoHistoryHandoffSafety`](../tla/UndoHistoryHandoffSafety.tla) | One old action H plus a completed new capture N while its index loads; at most four undo/redo admissions, one remote arrival, one crash; separate prefix/title/overlap/delete/conflict scenarios | No lost/duplicate action owner; new-before-old ordering; refusal preserves cursor; remote/current-only effects survive; note/cursor recover together; actual redo of both H and N; conditional index/command settlement |

The native model assumes correct span attribution from the concrete bridge. Its prefix cursor is a finite fixture, not an identity derived from arbitrary text length. The handoff model starts after N's complete durable capture; it does not prove keystroke admission, retain actual `NSTextView` invocations, or run a second peer's transport/installer. Remote input can intervene while idle/preparing, including between undo and redo, but not during the admitted pending command. The actual reducer must fence/recompute that additional race. Missing origins, multi-note scopes, rich bodies and arbitrary action chains remain outside these bounds.

All **29** new TLC configurations completed with expected outcomes: **8 positive exhaustive checks, 12 mutation controls, 9 reachability witnesses**. Positive distinct states: handoff prefix/progress 5,520; title/conflict 5,238; overlap 2,525; delete 2,455; spans safety/progress 3,266. Fairness is confined to the named local loading/settlement/recovery actions; no provider fairness is assumed. These are finite checks, not unbounded proofs or evidence that all user scenarios are solved.

Controls reject dropping new entries on late index publication, duplicate ownership, popping before refusal, raw/stale remote overwrite, unchecked overlap, conflict consumption, split note/cursor persistence, marking a partial span wholly undone/redone, split coverage persistence and clearing later pending work. Witnesses separately reach partial recovery, stale completion, guarded remote undo, intervening-remote rejection, and undo/redo of both actions. Self-review strengthened witnesses to require the actual recovery/redo/rejection transition; a mere final body or two repeated undo/redo cycles on N is not evidence that H was redone. Recovery does not pretend private native groups survived relaunch.

## Remaining integration gates

| Question | Required concrete experiment before adopting the bridge |
| --- | --- |
| Does every mutation get the right span? | Actual LinkingEditor typing, selections, paste/drop, formatting-only actions, multi-range edits, list/link transformations, title/labels, external-editor return; compare full before/after values and marker ownership. Exercise one native group crossing several captures, not only the aligned-span fixture |
| Can capture be bounded without disturbing input? | Continuous physical typing, long/nested commands, command-tracking/modal run-loop modes, undo during in-flight sealing, note switch/close, immutable attributed snapshots; measure capture latency and deadline drift. Never perform encoding or a filesystem barrier in an undo notification |
| Are IME/corrections safe? | Real input method with marked replacement/cancel, Escape, focus change and close; actual autocorrection/undo; remote arrival while marked. Verify committed snapshot versus draft and no duplicated/dropped input. No human IME evidence exists yet |
| Does handoff preserve every eligible local action? | Remote prefix/overlap/Delete/title, queued-but-not-yet-published reductions, edit during preparation, old index arriving after new typing, repeated handoffs and different note/collection scopes; one owner and no cursor change on rejection |
| Is saved partial coverage real? | Decode actual action/operation bytes after partial undo, redo, fresh branch and crash at each installer stage; relaunch uses remaining effects. Pending local compensation versus remote reduction must refence, not silently suppress either input |
| Are UI consequences acceptable? | Honest Undo Saved Edit labels after relaunch/body handoff, keyboard-only review/return, independent conflict notes unchanged, native granularity on unaffected notes, all-or-none named actions and fresh-birth delete/redo. Coarser granularity after a remote body change needs explicit acceptance |

The TextKit and TLA skills informed the explicit TK1 setup, separated mutation stages, stated bounds, negative controls and transition-specific witnesses. They do not certify the remaining implementation.

## Reproduce and inspect

```sh
make -C tests run-native-undo-probes
python3 tools/run-native-undo-probes.py --binary /tmp/notation-integration-tests/NativeUndoProbe --only span-
# Optional; own synthetic window, close to finish:
python3 tools/run-native-undo-probes.py --binary /tmp/notation-integration-tests/NativeUndoProbe --interactive
python3 tools/run-native-undo-probes.py --binary /tmp/notation-integration-tests/NativeUndoProbe --only shared-
python3 tools/run-native-undo-probes.py --binary /tmp/notation-integration-tests/NativeUndoProbe --interactive-shared
python3 docs/impl-proposal-5/check-history-rules.py
python3 docs/tla/check-segment-models.py --java /path/to/java --jar /path/to/tla2tools.jar --only undo- --timeout 120
```

Build the Intel probe with `make -C tests /tmp/notation-integration-tests/NativeUndoProbe-x86_64`; copy that binary and the runner to an explicitly authorized test directory on the peer. No cloud folder is needed. Logs intentionally distinguish assertions from observations: reproducing the unsafe native-remote sequence is not a positive rebase result.

Temporary raw evidence (reproducible sources above are the durable record):

- Local 31-case run: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-native-undo-vzum27d9`.
- Intel run on the Mini: `/tmp/nv-native-undo.vI6XEW/results-final-v2`.
- Physical-keyboard trace: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-native-undo-d39s8u1u`.
- Final 29-case model run: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-segment-tlc-6d2wp78a`.
- Existing 21-case action/recovery regression: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-segment-tlc-ijy0va7q`; all expected outcomes, unchanged 826/826/796 positive edit/bulk/restore state counts.

The history reference checks and `./build.sh` also passed. The build emitted nonfatal sandbox-related Xcode service diagnostics. No production undo or new live-provider contract was exercised by that build.

## Shared-window follow-up

The probe now includes **20 additional cases**, bringing its inventory to 51. They construct two independent TextKit-1 layout managers/text views over one note-owned storage/undo manager; a second note tests retargeting. A small *candidate* input-boundary adapter freezes an attributed committed snapshot only outside its outer `insertText:`/`setMarkedText:` call and while no attached view is marked. Snapshot counters are in-memory instrumentation, **not disk saves or segment acknowledgments**. Existing grouping/capture policy remains unchanged.

The complete suite ran on macOS **26.6.2** and Intel **14.8.9**. Ordinary cases contain concrete assertions; the runner now prints `OBSERVE` for observation-only cases (the original `remote-storage` and `remote-reset`) and opt-in human runs. Passing a case does not turn an unsafe accompanying observation into a guarantee. No NV launch, production model, provider, note files or general clipboard was involved.

| Experiment | Measured result and limit |
| --- | --- |
| Type in A, shared Undo/Redo; paste in A and format in B; explicit replacement | Both views reflect the same attributed state. One insertion produces one body transition; edit/undo/redo freeze three committed snapshots, not six. Formatting undo/redo restores the exact tested attributed value. These are not counts of actual NV segment admissions |
| Alternate A/B/A with and without explicit coalescing breaks | Both runs undo to `seedAB`, `seedA`, `seed`. This synthetic selection/input sequence does not settle physical focus-switch grouping policy |
| Retarget originating A from X to Y, edit Y, Undo/Redo X through its owner | Y's independent `seedY` edit survives X's Undo; Y's Undo leaves redone X intact |
| `replaceTextStorage:` control versus single-layout detach/rebind | The convenience API transfers **both** layouts to Y, as its SDK declaration documents. It is inappropriate for switching just A. The tested detach/rebind affects only A |
| Close/release A; or close/release both views then reopen X | Closed-view `dealloc` counters are asserted **before** executing undo/reopening. Undo/redo still restores X's tested values, including exact attributed snapshots in the format-only variant. A no-window variant and unused-view control also pass. Thus this result does not rely on an invisibly retained originating text view |
| Independent selection and temporary highlighting | B's programmatic selection updates the note's remembered range without changing A's live selection. Layout-local highlighting does not affect B or authoritative text, and creates no body undo |
| Admission failure from either view; refused Undo from B | Neither note body nor undo position changes; the same command works when admission recovers. Command refusal is checked before consuming an undo entry |
| A marks `n`, then `ni`, then commits `你`; explicit synthetic cancellation | B displays the shared draft but reports `hasMarkedText == NO`. The candidate committed snapshot stays `seed` during the draft, becomes `seed你` after commit, and returns to `seed` on undo. Explicit empty replacement cancels the synthetic draft without leaving its body behind |
| Inject a B insertion while A remains marked | Without the note-wide gate, final text is `Bseedn你`: the old preedit `n` remains. This is an injected public-method interleaving, **not** evidence that a real focus transfer/input method behaves this way |
| Gate B/remote application while A is marked | B's edit is refused and the proposed remote application deferred; after composition finishes B can edit. No blanket collection-level durability suspension is justified |
| Resign first responder and close A while synthetically marked | A can remain marked with `seedn` in storage. Do not assume a window close or the peer's unmarked flag supplies a committed snapshot/finished input context |

Two important harness refinements prevented false conclusions. First, a 50-ms run-loop drain left even an unused view alive. A longer **bounded** `NSApplication` turn allowed teardown; the final check uses observed deallocation counts, never elapsed time as proof. Both original views are gone before the reopened-view test. Second, storage editing notifications can occur *inside* an input-method call before the marked flag is established; the composition trace records such a notification. Merely scanning `hasMarkedText` inside that notification is insufficient. The input-depth/committed-snapshot adapter supplies the tested guard, but is not yet the complete set of NV mutation paths.

Apple's [text-system architecture](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextSystemArchitecture/ArchitectureOverview.html) supports multiple layouts over shared text. Its [multiple-view example](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextUILayer/Tasks/MultipleViews.html) also explains why several containers in one layout manager are flowing text, not independent note windows. Current SDK ownership declarations and actual deallocation measurements take precedence over extrapolating older archive ownership descriptions. No API contract violation was established.

### Ownership model and remaining concrete gates

`SharedNoteViewOwnershipSafety` adds **21 completed TLC configurations: 4 positive exhaustive checks, 9 mutation controls, 8 transition-specific witnesses**. Lifecycle safety/progress explore 2,056,617 states; routing 1,544,714; composition 147,212. Final runs use a 300-second per-case limit (largest elapsed time about 142 seconds), no graph/depth constraints, and complete with empty queues. An earlier 120-second liveness timeout was inconclusive and is not counted as a pass.

The model bounds two notes/two views, X's edit/undo/redo and Y's independent edit, three lifecycle attachment changes (two in routing), one root change/imported remote edit/UI request where enabled, one composition and one crash. It separates prepare/admit, observer notifications, attachment changes, immutable capture/write/install/completion and recovery. The composition fixture separates a visible draft from committed state so Y can be saved while X remains marked. Local fairness applies only to capture/installation/completion/recovery, never to user approval, composition completion or provider availability.

Controls reject duplicate observer-generated actions, window-owned undo, losing pending work on close, retargeted/stale admission and render callbacks, capturing draft bytes, split note/action cursor installation, and stale completion clearing newer work. Witnesses require actual Undo after the edit's origin detaches; Undo after **both** views close following that edit and one reopens; actual rejection after a remote generation change; rejected UI delivery; local-operation recovery before callback; stale completion; and a Y installation **during** X's draft (not merely starting a draft after Y was saved).

This model is an ownership/committed-state bridge, **not an `INSTANCE` composition or refinement proof** of AppKit and the segment installer. Its scalar command cursor is not a native stack or caret range. Imported remote state is a validated input, not modeled transport. Existing span/handoff, reviewed-undo and two-host action/recovery models cover adjacent contracts; their passing regressions do not automatically compose those proofs.

Before production adoption, run the following against the real implementation:

1. Instrument the actual note admission, undo/remaining-effect update and segment capture IDs through typing, rich formatting, paste/drop, multi-range changes, automatic list/link transformations, title/labels and external-editor return. Repeated view observers must add no extra operation. Verify actual bytes after crash at each installer stage, including a second window editing while an older capture completes.
2. Execute real IME conversion/commit/cancel, Escape, autocorrection, focus transfer, origin close and remote arrival. The note-wide gate alone is not a complete close/focus solution: finish the input context without losing draft input or leaving the surviving view blocked. The optional two-window probe exercises real input but is not itself an automated acceptance oracle.
3. Verify actual LinkingEditor/view-manager detach, object deallocation, note switching, closed-window command delivery, per-note Undo menus and saved-action handoff. Keep model/history alive; release actual view resources. Locks/root switches must clear view-held plaintext and stale consent without losing pending admitted state.
4. Refactor shared collection ownership versus per-window query/list state under the required human UI review. Test synchronous search, independent selection/scroll, remembered-cursor last update wins, Recently Deleted's separate read-only window, keyboard navigation, accessibility and return of focus. The fixture does not prove the existing AppController/NotesTableView paths are reusable unchanged.

Manual sequence: run `--interactive-shared`, use only synthetic text, replace `seed` with `alpha` in A, type in B, Undo from A and Redo from B, then test an actual input method while changing focus and pressing Cmd-S. Close A and continue undo/edit in B; close both windows to finish. Cmd-S is an instrumented boundary only, not a disk write. The interactive fixture keeps its attachment wrappers until the run ends; use the automated deallocation cases for lifetime evidence. No new permissions are needed. No new human two-window/IME run has been counted yet.

Final artifact paths are recorded in [Verification](Verification.md#shared-note-window-ownership-follow-up). The TextKit/TLA skills guided independent layouts, explicit stage boundaries, finite scenario bounds and non-vacuity controls; they do not certify the remaining integration.

## Registered external-edit follow-up (2026-09-14)

The [new measurements and exact limitations](plan/remaining-storage-validation.md#registered-external-undo)
add four registered-edit cases passing on macOS 14.8.9 and 26.6.2, plus a fifth
later-typing/Undo/Redo case passing locally on 26.6.2. These use the public
multi-range editing protocol with registration enabled and preserve older fine
typing groups in ordinary LIFO order. They do not prove selective rebasing,
causal eligibility, real IME or NV's production router. No Undo Saved Edit
fallback or production editor change is adopted.
