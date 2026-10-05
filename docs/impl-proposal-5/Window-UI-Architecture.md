# Shared note windows and Recently Deleted Notes

Part of [proposal 5](README.md). This document consolidates the agreed features and describes the UI ownership separation needed to build them. It is not a claim that the existing single-window application already implements that separation. The [specification](../iCloud-Drive-Support-Spec.md#note-history-recently-deleted-and-undo), [history ADR](../adr/0015-retain-history-and-use-compensating-undo.md), [vocabulary](../../CONTEXT.md) and [implementation contract](Implementation.md#history-recently-deleted-and-cross-launch-undo) retain their authority. Candidate AppKit mechanisms and unresolved details are identified below.

## Feature contract

### New Window: another view of the same notes

**New Window** opens another ordinary notes window onto the same active collection, backing store and live in-memory note objects. It does not copy the repository, reopen a second writable database, create a writer identity, or fork the note's undo history.

Each window has its own search text/filter, selected note, list scroll offset, editor selection/scroll, layout, geometry and focus. A user can keep one search open while searching for something else in another window, or display the same note in both. Search remains synchronous, in the input/view-refresh cycle; separating window state does not authorize background or debounced search.

Editing a note in A changes the shared note displayed in B. There is no later window-to-window save, synchronization or conflict-resolution step. Windows showing other notes retain their own selections; each filtered list responds to the shared model change according to its own query. A command in A must not act on whichever note B most recently selected.

Undo/redo belongs to the note, not the window. If A edits X and B also displays X, Undo from B can reverse A's edit. If A switches to Y, its commands target Y; X's history remains available through B or a later attachment. Named collection/bulk actions retain their existing collection scope and must not be duplicated onto each affected note's stack. Window-local search-field editing remains presentation behavior, not a saved note action. The shared router selects portable causal candidates before consuming any native note entry; native range validity or `canUndo` alone cannot bypass a later remote action or an incomparable candidate.

Closing a window releases its presentation resources, not the note's undo owner, admitted edits or pending saves. Closing every view of X and later displaying X must not depend on keeping the original text view alive invisibly. Closing the last window does not itself authorize discarding collection state; any resulting application quit still follows the existing asynchronous durability/termination contract.

### Recently Deleted Notes: a separate viewer

**Recently Deleted Notes** opens a separate, nonmodal viewer window. It never replaces the ordinary window's notes list, search or editor with a deleted-items mode. Its title and read-only presentation must make its purpose clear; the main notes windows remain available. Reuse list/search/presentation logic where applicable, not a second storage model or a second copy of `AppController`'s application lifecycle.

The viewer lists applicable logical Deletes and their retained prior values, including known remote deletions. It is not a filesystem Trash browser. Unexplained disappearance of a separate note file stays in the external-deletion confirmation flow; it does not become a logical Delete just because this viewer exists. Ordinary note lists/search counts continue to exclude deleted entries.

Selecting an entry shows a detached, selectable read-only preview. If its pre-delete history has multiple branches, expose those choices rather than inventing a unique last value. Missing historical bytes produce an entry-specific availability state, never substitution of Current or a claim that the provider disclosed all history. Local retained history remains usable offline after unlocking. This feature does not add full-history text search.

The recovery control is **Restore**. It creates a fresh ordinary note birth/UUID from the selected retained value; it neither reactivates the deleted birth nor erases its Delete/retirement. Preserve supported content/format and captured metadata, record the exact source deletion/revision in restoration provenance (`restoredFrom`), and collision-adjust the output name without clobbering a same-name file. Do not offer a redundant **Save as new note** button here. That separate-copy choice remains meaningful in Note History and conflict resolution, where replacing an existing note is another available action.

A recovery uses ordinary mutation admission, action recording, local segment durability and applicable separate-file installation. Once the restoration and its provenance are locally durable, remove the source entry from the default Recently Deleted listing: to the user it effectively moves back to ordinary notes. Do not wait for plaintext file installation, cloud upload or another Mac. While the action is pending or its local barrier has failed, retain the entry with that action's status; retries finish the same action rather than creating a second note. Closing the viewer cannot lose admitted work. Concurrent explicit restorations on two Macs can produce two notes; do not promise global exactly-once restoration.

The recovered note joins the shared live model on admission. Each ordinary window's result list reflects it if it matches that window's query; recovery does not retarget every window. The temporary pending entry is not a second live note. Undo of recovery is guarded undo of a new creation, not deletion of the retained source history. A restored deterministic conflict note also receives a fresh ordinary birth, leaving its original retirement intact.

Default-list exclusion derives from the complete durable restoration provenance, not a window-local hidden flag or a test that the new note is still live. Restart/index reconstruction reconstructs it; another Mac applies it once it has validated and locally persisted the restoration's dependency closure. Deleting the restored note later produces a new entry for that fresh birth and its then-current recoverable history; the original entry stays excluded. This also applies if guarded Undo of Restore deletes the new birth. The old deletion, all prior branches and the restoration link remain inspectable through history; hiding the named source entry does not resolve unrelated conflicts or other deletion entries.

"Recently" does not promise a 30-day lifetime. V1 has no expiry, automatic purge, **Delete Permanently** or **Empty Recently Deleted** operation. Removal from this default listing is not removal of historical evidence. Unavailable provider work must not trap the user in this window, and closing it after admission cannot cancel or duplicate the accepted restoration.

### Note Bookmarks: a dedicated window per saved search

Saved searches graduate from search-loading shortcuts into window-backed views. Each bookmark can be opened in its own dedicated ordinary notes window showing its saved search. Activating a bookmark — clicking its entry in the Note Bookmarks window or pressing its associated numeric shortcut — opens that bookmark's dedicated window and brings it to the foreground, instead of loading the saved search into whichever ordinary window was most recently active and displacing that window's search, selection and scroll position. The dedicated window comes into existence on first activation and is reused from then on: activating an already-open bookmark foregrounds its existing window rather than opening a duplicate.

A bookmark window is an ordinary notes window under the New Window contract above: same shared collection, backing store, live note objects and per-note undo, with its own presentation state initialized from the bookmark's saved search and its remembered last-selected note (`NoteBookmark` already retains the note UUID for this). Everything in the shared-model sections applies unchanged — synchronous search, per-window selection/scroll/layout, model-bound mutation admission, and closing the window releasing presentation state only, leaving the bookmark available for a later activation.

A dedicated window's position and size are saved alongside the rest of the bookmark data: the window frame joins the search string and note UUID in the bookmark's persisted representation, written through the existing bookmarks preference-saving path. This retention is bookmark-scoped, private UI preference data in the same store as the bookmarks themselves; it is not the general serialized window-session format ruled out below.

Open bookmark windows and their associated searches are remembered across app launches. At launch the remembered windows reopen presenting their associated saved searches, extending the existing cross-launch restoration that already reopens the Note Bookmarks panel itself. Remembered windows reopen only for bookmarks that still exist, and this restores bookmark windows only: it adopts no promise to restore arbitrary ordinary windows.

`BookmarksController` keeps ownership of the bookmark list, its numeric shortcuts and the bookmark-to-window association, and routes activation through the application coordinator's open-window management rather than funneling every restore into `AppController`'s single visible window (`bookmarksController:restoreNoteBookmark:inBackground:` → `searchForString:`/`revealNote:`).

## Ownership separation

Extract window/UI state out of the current `AppController` while preserving one shared collection/model owner. These are responsibilities, not a requirement for a class or framework per row.

| Owner | Shared or independent state | Boundary |
| --- | --- | --- |
| Application coordinator | Application lifecycle, open-window management, collection ownership and application-wide commands | Opens ordinary/viewer windows and routes commands using an explicit window context; it has no single universal `currentNote` |
| Collection/session, retaining `NotationController`'s model responsibilities | Live note objects, collection-wide indexes, local store/root session, admission gate, pending captures, history/action indexes and collection-scoped undo | One authority for note changes and durability; no active window's mutable query/result list masquerading as collection state |
| Per-note model/editor ownership | Authoritative content, note generation, per-note native/saved undo and remaining-effect metadata, AppKit input-context integration, remembered cursor range | Survives attachment changes; observers do not register duplicate actions or captures |
| Each window controller/presentation | Query and incremental filter state, result rows, selected item, live caret/selection, scroll, geometry, focus, layout/highlighting and preview/request generation | References shared identities/objects; contains no independent note content database, durable action branch or provider lane |
| Read-only history/deleted/resolver presentation | Detached selected revision value, preview selection and explicit invocation/request context | Cannot mutate a live note through text notifications or acquire mutation authority merely by reusing a widget |

Use one reusable ordinary-window controller and the smallest shared list/preview components needed by the deleted viewer. Their different entry sources and allowed commands are explicit. A deleted row is a history reference, not a fake editable `NoteObject` inserted into the live store. Avoid spreading an `isRecentlyDeleted` mode through note storage, ordinary search and persistence.

Window presentation state is runtime state, with any explicitly retained UI preferences remaining private. No serialized window-session format or promise to restore every open window at launch is adopted here; the per-bookmark window frames and remembered open set of the saved-searches contract above are retained as private bookmark preference data, as the bookmarks panel's existing cross-launch visibility already is. In particular, there are no persisted per-window copies of note bodies or undo stacks.

### Remembered cursor versus live selections

Keep one remembered cursor location/length per note. The most recently updated valid range wins, including programmatic changes, regardless of which ordinary view supplied it. Do not retain the old policy of ignoring a range merely because it was set automatically. Validate ranges against the relevant text generation; stale attachment callbacks cannot update another note's remembered range.

Open views still have independent live selections. Updating X's remembered range from B does not move A's caret to B's location; when AppKit must adjust a selection because shared text changed, that is not cross-window caret mirroring. Remembered selection is UI state, not a body `Put`, undo action or cross-machine ordering clock. Selecting text in a detached historical preview does not update Current's remembered cursor.

### Shared text, independent layout

The tested minimal candidate for NV's macOS 11.5+ AppKit UI is one TextKit-1 `NSTextStorage` per live note, with a separate `NSLayoutManager` / `NSTextContainer` / `NSTextView` chain per attached editor. The note owns text and undo; each view owns its layout and interaction state. Temporary search highlighting belongs to a layout, not the authoritative attributed content.

Multiple containers on a single layout manager form flowing text, not independent complete-note views. Also, `replaceTextStorage:` transfers all layout managers from the old storage: switching A to another note must detach/rebind just A's layout, not move B with it. These are concrete findings from the [shared-window probes](Native-Undo-Experiments.md#shared-window-follow-up), with limits recorded in the [Apple API ledger](../Apple-API-Contract-Validation.md#native-undo-observations-integration-evidence).

Recently Deleted and historical/resolver previews instead own detached read-only text. `ConflictResolverView` swaps into the split-view subview in place of `LinkingEditor`; it uses an `NSTextView` or equivalent capable read-only text control, not overrides of LinkingEditor's persistence machinery. The same preview components can serve the separate deleted viewer without sharing live editable text storage.

This is not a TextKit-2 migration or a SwiftUI rewrite. Production editor, table, search and responder changes still require the explicit human review and testing specified in `AGENTS.md`.

## Mutation, commands and lifecycle

An ordinary edit follows one model-bound path:

1. Resolve the invoking attachment's collection, note birth and generation; check shared admission before text mutation or undo consumption.
2. Admit the logical change once through the note/model owner. Other views update their presentation; their notifications cannot replay the edit, register another undo entry or create another pending generation.
3. Capture immutable committed note/action values using the existing batching policy. Sharing views does not introduce a per-keystroke segment or replace durability capture with window-close notifications.
4. Install locally on the existing durability lane. Model-bound pending work survives window changes; UI completion requires a still-valid attachment/request generation and cannot clear newer work.

Menus, table keys, toolbar/context actions, paste/drop, external-editor returns and Undo/Redo must all resolve their intended context. Setting a preview text view noneditable is insufficient if its reused table still routes Delete or Rename to the application's last ordinary selection. The deleted viewer permits selection/copy and explicit recovery, not ordinary editing, implicit note creation from its search field, rename, or permanent deletion of a history row. Define command validation at the presentation boundary and keep mutation admission in the shared model.

Preview/review requests capture their invocation mode and target independently of which window later becomes key. A pending **Review Undo** continues that captured command; opening explicit Note History remains a separate historical-recovery action. Sharing presentation does not change redo semantics or confer Apple-version resolution authority. Another window's edit can invalidate a prepared review, requiring fresh preparation/approval, not silent retargeting.

Follow the [platform-first input contract](../iCloud-Drive-Support-Spec.md#input-and-content-scope): preserve AppKit's normal composition and local focus/close/note-switch behavior rather than create NV-specific cancellation rules. A peer can display another view's marked text while reporting no marking itself; this is a warning about arbitrary storage snapshots, not proof that normal focus transfer fails. Prefer postponing remote body application until a safe input boundary, then revalidate and merge/review only when the existing policy requires it. Do not interrupt typing merely to save or label composition itself a conflict; other notes and local durability continue. Separate committed snapshots and the probe's input-depth/refusal adapter are implementation candidates only. Test real event delivery before requiring a custom handoff.

On detach/close, invalidate that attachment's unadmitted requests and release its layout/view resources; retain admitted note work and history in their shared owners. A late completion must not reopen a window, switch another window's note, or survive an X→Y→X attachment change unnoticed. Lock/root changes also invalidate preview consent and release view-held plaintext across all affected windows. Keep detached previews accessible by keyboard, selectable for copying, and dismissible; restore focus appropriately without imposing state on unrelated windows.

## Where the current source must be separated

These are migration seams, not approval to replace working keyboard behavior wholesale.

| Existing code | Required separation |
| --- | --- |
| [`AppController.h`](../../AppController.h), `_setCurrentNote:`, `selectedNotes`, view delegates | Move window outlets, selected item and presentation bookkeeping to the window owner. Keep application/collection lifecycle shared. Resolve row indices through that window's result list, not a global list |
| [`NotationController.m`](../../NotationController.m) `filterNotesFromString:`, `refilterNotes`, `filterNotesFromUTF8String:forceUncached:` | Separate mutable filter/results/autocomplete state from shared notes and query-independent search data. Preserve the synchronous algorithm. Audit query-dependent cached match positions in `NoteObject` too: extracting only the query string is insufficient |
| [`AppController.m`](../../AppController.m) `textDidChange:` and [`NoteObject.m`](../../NoteObject.m) content setters | Replace the assumption that the one visible editor copies into the one `currentNote`. Establish once-only shared mutation attribution without dropping dirty/cache/external-edit bookkeeping |
| `undoManagerForTextView:`, `windowWillReturnUndoManager:` and `windowUndoManager` | Preserve note versus collection scope, with presentation-field undo kept separate. No second saved-action owner or collection stack per new window; closing the origin must not invalidate native/saved undo |
| `AppController` selection saving and `NoteObject setSelectedRange:` | Implement last-update-wins remembered ranges, including programmatic selections, without creating content-history operations or synchronizing every live caret |
| [`NotesTableView.m`](../../NotesTableView.m) keys/editing/drop and application-delegate calls | Supply the correct window/list context and allowed actions. Existing Return-to-rename and Delete-to-app-delegate paths cannot be reused unchanged in a read-only deleted viewer |
| `AppController windowWillClose:` / quit handling | Separate a window closing from shared collection shutdown. Do not apply the single-window quit preference blindly to every viewer window; preserve one coordinated termination path |
| [`BookmarksController.m`](../../BookmarksController.m) `restoreNoteBookmark:inBackground:`, `restoreBookmark:`, `doubleClicked:`, `tableViewSelectionDidChange:` | Route every bookmark activation to the bookmark's dedicated window through the application coordinator, replacing the funnel through `bookmarksController:restoreNoteBookmark:inBackground:` into the one main window's `searchForString:`/`revealNote:` |
| `NoteBookmark dictionaryRep` / `initWithDictionary:`, `BookmarksController restoreWindowFromSave`, `GlobalPrefs saveCurrentBookmarksFromSender:` | Persist each bookmark's window frame with the rest of its bookmark data, and reopen the remembered set of bookmark windows at launch alongside the panel itself |

Extract and verify the ordinary single-window path first, then attach a second ordinary window, then reuse the resulting presentation pieces for per-bookmark windows and Recently Deleted. Do not introduce an alternate persistence engine, per-window synchronization system, general scene framework or on-disk metadata solely for these features.

## Evidence and remaining decisions

The [AppKit report](Native-Undo-Experiments.md#shared-window-follow-up) records tested shared editing, formatting, independent selections/layouts and Undo/Redo after actual destruction of the original views on macOS 14/26. These are synthetic call-sequence results, not completed NV integration. [`SharedNoteViewOwnershipSafety`](../tla/SharedNoteViewOwnershipSafety.tla) checks once-only admission, attachment fencing, pending-work survival, crash recovery and committed-state/draft separation in bounded scenarios; it assumes correct native attribution. See the [model guide](../tla/README.md#proposal-5-segment-coverage--adopted-design) before interpreting those checks as proof of production behavior.

The remaining implementation gates are the actual LinkingEditor mutation/undo/segment bridge, real IME and autocorrection focus/close behavior, actual object teardown, and human keyboard/accessibility testing of independent filters, selection and command routing. Neither shared text storage nor the model proves them automatically.

The following UX details are not settled by the ownership design:

- New Window's initial query/selection, placement, shortcut and which presentation state is restored across launches.
- For bookmark windows: whether search-field edits inside a dedicated window update its bookmark's saved search or only filter that window; how removing or reordering bookmarks — and their positional numeric shortcuts — treats an open dedicated window (close it, retarget it, or leave it open unassociated); and how the Note Bookmarks table indicates which bookmark's window is key while several are open. Their initial query, saved placement and cross-launch reopening are settled above rather than open.
- Whether Recently Deleted reuses one existing viewer or permits several; exact list filtering/sorting, branch/action presentation and post-restore focus/navigation. Source-row removal after local durability is settled; it is not an open presentation choice.
- How the existing quit-on-window-close preference applies to the last ordinary window when viewer windows remain. Closing an arbitrary auxiliary window must not accidentally run the old single-window quit path.
- Qualification of ordinary AppKit input-context behavior in the actual shared editor, especially remote application during composition; consult contracts/HIG before proposing custom behavior. Test registered external undo changes before any coarser fallback. A remaining UX trade-off requires explicit approval, not an assumption inferred from synthetic peer-input probes.

None requires inventing a per-window store or weakening the agreed shared-model/per-note-undo behavior. Resolve them before shipping the relevant UI, without delaying the documented separation itself.
