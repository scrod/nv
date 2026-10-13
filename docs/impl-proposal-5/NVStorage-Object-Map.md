# NVStorage unified object map

Date: 2026-10-13. Explanatory architecture inventory of the adopted segment-collection design. The normative specification, algorithm/wire annexes, ADRs and vocabulary retain their authority. The diagram includes documented Core, Runtime and Apple work alongside planned projection/application consumers, with implementation and qualification boundaries marked.

[Scenario reference and interactive map](diagrams/nvstorage-object-map.html) · [Scenario document](diagrams/NVStorage-Scenarios.md) · [Full-size SVG](diagrams/nvstorage-object-map.svg) · [Object inventory](diagrams/nvstorage-object-map.json) · [Editable hierarchy and traces](diagrams/nvstorage-object-map.layout.json)

The inventory contains 60 object groups, 140 labeled operations/relationships, and all 27 current private SQL tables. Containment represents process, directory and file boundaries; subheadings identify functional groups. The live in-memory session, private SQL store and provider repository have distinct responsibilities and boundaries.

The scenario index contains 48 cases in 7 categories. Each case records initial conditions and an expected outcome, followed by three processing stages with observable state, storage operations and applicable rules. The map highlights objects read/consumed, written/produced, and checked as gates for the selected stage. Object controls open the corresponding inventory details and retain a return path to that stage. Previous/Next, numbered steps and Left/Right keys navigate. Search covers scenario text, object names, requirement IDs and test-contract IDs; the requirement filter covers all 16 registry entries. References link each case to source sections and named conformance contracts. Implementation and platform qualification are recorded in the linked plans and reports.

The architecture-map view emphasizes structure. All SQL roles are nested inside `Collection.sqlite`; pager sidecars are siblings in its database-file bundle. Private unlock copies are outside that bundle, and the selected-store record sits outside either active or replacement store. Repository descriptors and segment objects sit inside the `NV Data/v1` hierarchy. Snapshot root/page families share the segment namespace. Apple unresolved-version evidence sits outside the physical repository boundary as associated OS state.

Functional groups say **Feature group**, **Operation values**, **Logical roles**, or **Session resources**. These express similarity and purpose. The enclosing process/directory/file/bundle labels establish physical or lifetime containment. Recovery/output locations have their own explicitly associated boundaries.

Choose an operation trace to highlight its objects and show numbered stages in their existing locations. The trace panel explains what derives or commits each stage and exposes its exact relationships. Clicking one relationship draws that connector alone; clicking a card shows its members, incoming/outgoing operations, features and source contracts. Feature highlighting and object/SQL search preserve the same hierarchy. The interactive view initially fits the map width and scrolls vertically; zoom and whole-map controls support broader inspection.

During use, the complete live note store is authoritative and search is synchronous. The save route freezes admitted generations, seals exact bytes, validates complete groups, and atomically retains history/acceptance/pin/wakeups. The receive route retains incoming bytes first, waits for the appropriate byte/history requirements, validates and accepts, then prepares generation-fenced reduction. These routes join at accepted history, whose durability precedes external effects.

Private current rows/context accelerate reopening through an exact accepted prefix. Provider snapshots describe a verified logical operation cut; general v1 retention-parent links cover object closures independently. Recovery includes every accepted outside-cut action. Both representations retain their own validation and final-publication checks.

Operation causal parents, note predecessors, action scope parents, compensation targets, and snapshot retention parents answer separate questions. A pin, stamp, receipt, decoded ID, upload status, and physical permission also have distinct issuing and consuming boundaries.

The source corpus contains 120 specification, annex, ADR, plan, validation and coverage documents, including working-tree updates and planned work. The [source manifest](diagrams/nvstorage-object-map.sources.json) records every path and SHA-256 at generation. Current adopted contracts govern where earlier experimental reports describe a discarded alternative. Test fixtures, compiler probes and benchmark-only synthetic objects are evidence; scalar ID wrappers, codec cursors and allocation buffers are grouped with their owning records/jobs. The same map applies independently on each Mac.

![Nested NVStorage object diagram](diagrams/nvstorage-object-map.svg)

Feature letters: **E** Editing & search; **D** Local durability; **S** Sync & discovery; **B** Startup & bootstrap; **H** History & Recently Deleted; **M** Merge & conflicts; **U** Undo / Redo; **P** Plaintext / external files; **K** Encryption & unlocking; **R** Repair / backup / copy; **Q** Quit & lifecycle.

## Scenario reference

[Scenario descriptions and source references](diagrams/NVStorage-Scenarios.md). The following links open individual walkthroughs:

### Local editing, durability and startup

Edit admission and capture, SQL acceptance, accepted-prefix startup, verification replay, and derived-row reconstruction.

- [Local save while the provider is unavailable](diagrams/nvstorage-object-map.html#scenario=offline-save&step=1) — With a healthy, unlocked private store, edits enter the live model immediately. The local SQL transaction commits exact history and its required bookkeeping before acknowledgment; provider publication remains pending.
- [Crash recovery before and after the local commit](diagrams/nvstorage-object-map.html#scenario=save-crash&step=1) — A pending edit becomes recoverable only after its complete local transaction commits. Recovery includes a committed action whose callback was lost; text still held only in RAM remains within the pending loss window.
- [Delayed save completion with a newer pending generation](diagrams/nvstorage-object-map.html#scenario=delayed-save&step=1) — Capture E contains AB. A later edit creates generation F containing ABC before E completes. E’s completion settles only E; F remains pending and its live value remains ABC.
- [Returning startup with optional snapshot work queued](diagrams/nvstorage-object-map.html#scenario=fast-startup&step=1) — Startup drains required Changes, prerequisites and unfinished verification, then captures all current rows and authoring context consistently. Independent optional snapshot work starts after checked publication of the editable model.
- [Startup with positively disclosed but unreadable newer evidence](diagrams/nvstorage-object-map.html#scenario=work-offline&step=1) — A complete returning local history can support Work Offline when startup is waiting for named, positively disclosed newer evidence. Generic provider unavailability is a synchronization status condition and does not require this choice.
- [Reconstruction of invalid derived current rows](diagrams/nvstorage-object-map.html#scenario=derived-rebuild&step=1) — Invalid current-row codecs, dictionaries or prefix binding require reconstruction from healthy retained history. Complete rows and authoring context install under a fresh view epoch while required private records and pending work are preserved.
- [Restart during retained-history verification](diagrams/nvstorage-object-map.html#scenario=verification-restart&step=1) — A durable request records the exact scope before a check that may discover retained-history damage. If checking, diagnosis or settlement is interrupted, reopening replays that obligation before editable publication.
- [Optional current-row recoding and full-VACUUM maintenance](diagrams/nvstorage-object-map.html#scenario=idle-maintenance&step=1) — Bounded row recoding preserves logical values and context under exact view/prefix checks. Opportunistic full VACUUM requires a healthy idle store, measured benefit and space budgets, and qualified interruption/commit latency; required persistence takes priority.

### Immutable history, merge and deletion

Dependency-aware reception and publication, note-head reduction, causal Delete/edit handling, and snapshot retention ancestry.

- [Receipt of a Delete before its parent edit](diagrams/nvstorage-object-map.html#scenario=child-first&step=1) — Mac B receives Delete D before edit P, which D observes. B retains D and its reverse waits across restart, then accepts and reduces the complete validated dependency closure when P arrives.
- [Publication retry after an uncertain completion](diagrams/nvstorage-object-map.html#scenario=publication-retry&step=1) — A retry reuses exact locally accepted bytes and identity. Equal provider finals still require verification and namespace barriers; foreign or contradictory occupants are preserved, and duplicate receipt adds one semantic action.
- [Automatic merge of strictly separated line edits](diagrams/nvstorage-object-map.html#scenario=separated-merge&step=1) — Two heads share a unique common base. One changes line 1 and the other changes line 3, with an unchanged line between them. If every field satisfies the conservative rules, reduction derives a combined Current while retaining both inputs.
- [Review after overlapping edits or a third head](diagrams/nvstorage-object-map.html#scenario=merge-review&step=1) — Overlapping or touching edits, ambiguous bases, a third head, or the two-sided line limit prevent automatic merge. All alternatives remain available; a prepared choice must match the complete current inputs at admission.
- [Ordinary editing of one unresolved head](diagrams/nvstorage-object-map.html#scenario=ordinary-conflict-edit&step=1) — An ordinary edit of displayed head A supersedes the represented A input. Known incompatible head B remains unresolved. Releasing the temporary local Current-head pin schedules reduction of the complete applied head set.
- [Concurrent Delete and offline edit on separate Macs](diagrams/nvstorage-object-map.html#scenario=delete-race&step=1) — Delete D and edit E are authored independently from the same note. Causal reduction deletes the old birth and preserves an otherwise eligible concurrent E in a deterministic conflict birth; an edit covered by D has a different result.
- [Retraction after a later Delete covers a preserved edit](diagrams/nvstorage-object-map.html#scenario=retracted-copy&step=1) — An initial Delete concurrent with E derives automatic copy C. A later Delete observing E can retract untouched C once no eligible source remains. Independent edits to C and still-eligible descendants of E remain preserved.
- [Snapshot retention ancestry and logical operation cuts](diagrams/nvstorage-object-map.html#scenario=snapshot-retention&step=1) — A general v1 snapshot can retain an exact accepted parent root independently of its represented logical cut. Parent-frontier changes commit atomically; all required ancestor bytes and accepted outside-cut actions remain part of recovery.

### History, restoration and compensation

Historical field recovery, fresh-birth Restore, causal Undo/Redo, native remaining-effect coverage, and shared-window ownership.

- [Historical body restoration with current title and labels](diagrams/nvstorage-object-map.html#scenario=selective-history&step=1) — Note History supplies an exact retained body for a new recovery action. Body restoration preserves current title and labels unless those fields are explicitly selected, and admission revalidates Current and the complete preview.
- [Named restoration followed by deletion of the fresh birth](diagrams/nvstorage-object-map.html#scenario=recently-deleted&step=1) — Restore creates a fresh birth linked to a named deleted entry. Complete durable restoration evidence excludes that source entry from the default list; deleting the restored birth later creates a separate entry.
- [Causal Undo after relaunch or on another Mac](diagrams/nvstorage-object-map.html#scenario=portable-undo&step=1) — Validated action records preserve exact members, before/after references and scope parents. Any Mac may compensate a unique applicable maximal action; incomparable or overlapping candidates require review, and bulk admission applies to the whole group.
- [Reviewed Undo with an actual-current inverse](diagrams/nvstorage-object-map.html#scenario=reviewed-undo&step=1) — Rename B was Shopping → Groceries, while a represented concurrent action makes Current Errands. Approved Undo B records Errands → Shopping; its Redo reverses that actual compensation to Errands.
- [Concurrent compensation of the same action](diagrams/nvstorage-object-map.html#scenario=concurrent-undo&step=1) — Two Macs can each admit compensation of X before learning of the other. U and V remain distinct actions. Candidate ambiguity is relative to direction and compensation family, and reversing one restored birth preserves the other.
- [Partial native Undo followed by relaunch](diagrams/nvstorage-object-map.html#scenario=native-remaining&step=1) — Partial native reversal records exact remaining-effect coverage for saved typing actions. Reopening derives portable eligibility from retained coverage and Current lineage, so an already reversed effect is not compensated twice.
- [Shared-note windows during composition and remote publication](diagrams/nvstorage-object-map.html#scenario=shared-windows&step=1) — Two windows reference one live note and per-note Undo owner while retaining independent selections. Remote body publication observes the native input boundary and revalidates note, attachment, store, root and lifecycle generations.
- [Dedicated saved-search windows and bookmark preferences](diagrams/nvstorage-object-map.html#scenario=saved-search-windows&step=1) — Each saved search owns a reusable ordinary window over the shared collection. Activation preserves other windows’ queries and selections; bookmark-scoped preferences retain frame and open state across launches.
- [Durable preservation of a selected unresolved revision](diagrams/nvstorage-object-map.html#scenario=conflict-copy&step=1) — Save as new note records exact copy and disposition evidence for the selected revision without superseding the source. Reciprocal explicit copies can produce distinct births; completed disposition survives later copy edits or deletion.

### Plaintext files and external versions

File observation and provenance, automatic import, pending input retention, projection installation, external deletion, and Apple version disposition.

- [Automatic import of an eligible ordinary text file](diagrams/nvstorage-object-map.html#scenario=automatic-import&step=1) — An ordinary unstamped file imports after provenance, availability and narrowly scoped repair-candidate checks. One admitted observation retains its retry identity; later duplicate knowledge preserves independently created births.
- [Projection stamp arriving before its named history](diagrams/nvstorage-object-map.html#scenario=stamp-waits&step=1) — A file with a projection stamp naming unavailable history waits for that exact evidence. Once the represented state and unique association validate against current bytes, the file associates with the existing birth without an echo Put.
- [Source change before external-file choice admission](diagrams/nvstorage-object-map.html#scenario=pending-choice&step=1) — A pending choice previews A, then the source changes to B before approval. Latest-reference replacement is durable and generation-checked; the old A preparation is rejected rather than retargeted to B.
- [Source change after external-file operation admission](diagrams/nvstorage-object-map.html#scenario=admitted-file&step=1) — An admitted operation retains frozen input A while newer B becomes a subsequent observation. After restart, exact operation/action evidence determines whether A committed; receipt recovery continues the same operation and birth.
- [Disappearance of an unadmitted pending external file](diagrams/nvstorage-object-map.html#scenario=disappeared-file&step=1) — The last durably retained readable snapshot survives later source disappearance or unreadability. Its bytes support renewed applicable decisions or explicit recovery, while association and physical effects still require fresh evidence.
- [External disappearance during deletion confirmation](diagrams/nvstorage-object-map.html#scenario=external-deletion&step=1) — A missing projection can trigger the configured external-deletion choice. File return, changed Current or a received committed Delete invalidates or changes that choice; a new local Delete still requires fresh admission and its complete local barrier.
- [New projection intent C while installation B is unfinished](diagrams/nvstorage-object-map.html#scenario=projection-abc&step=1) — A is the accepted projection when B starts. New intent C arrives before B’s installation or receipt completes. B settles only its captured output and serviced generations; C remains intended until its own applicable installation.
- [Scoped disposition of an Apple unresolved version](diagrams/nvstorage-object-map.html#scenario=apple-versions&step=1) — For captured version V, disposition follows admission, complete local history durability, exact plaintext installation and final coordinated revalidation. Only still-applicable captured members receive resolved = YES, followed by a fresh verification query.
- [External-editor handoff from an encrypted collection](diagrams/nvstorage-object-map.html#scenario=external-editor&step=1) — An explicit handoff uses owned plaintext scratch outside the provider namespace with disclosed external-app retention risks. Returned edits take the ordinary local barrier; cleanup applies only to the matching serviced scratch generation.

### Damage classification, repair and backup

Same-root repository repair, retained-history reconstruction, fresh-store activation, bootstrap, and complete private backups.

- [Automatic repair of positively absent same-root NV Data](diagrams/nvstorage-object-map.html#scenario=repository-repair&step=1) — With the same positively owned root, a complete private closure and no disclosed unread newer evidence, positively absent NV Data triggers automatic exact reconstruction. Exclusive creation preserves a competing namespace occupant.
- [Fresh-store repair from complementary retained copies](diagrams/nvstorage-object-map.html#scenario=private-repair&step=1) — A surviving pin requires G+L+R; private history supplies G+L and the repository supplies G+R. A validated union populates a fresh sibling, whose complete closure and retained pin must be durable before activation.
- [Required retained object missing from all available sources](diagrams/nvstorage-object-map.html#scenario=missing-history&step=1) — A surviving pin names a leaf or descriptor absent from private history, repository and selected backup. Editable publication waits for complete repair or an explicit recovery outcome; apparently valid derived rows cannot waive the dependency.
- [Fresh private-store bootstrap from a selected repository](diagrams/nvstorage-object-map.html#scenario=fresh-mac&step=1) — A new Mac or total private-state loss requires explicit physical association and complete verified bootstrap closure. A complete authenticated snapshot can support read-only preview while editing waits for required history and a durable fresh local pin.
- [Private backup containing unpublished and pending work](diagrams/nvstorage-object-map.html#scenario=private-backup&step=1) — A consistent keyed SQLite backup or quiesced complete pager capture includes unpublished accepted history, required private records and pending recovery links. Usable unlock descriptors accompany encrypted backups; restore establishes fresh ownership.

### Encryption profiles and credentials

Password/key recovery, add-only key wrapping, authenticated decoding, and explicitly requested plaintext output.

- [Password unlock with an unavailable remembered key](diagrams/nvstorage-object-map.html#scenario=unlock&step=1) — When Keychain is locked or unavailable, a usable wrapped descriptor and authorized password can recover the same collection key. Remembering a new key item requires add-only creation and verified readback before association refers to it.
- [Same-key password rewrap and full key/profile conversion](diagrams/nvstorage-object-map.html#scenario=password-rewrap&step=1) — Password rewrap adds a descriptor for the existing CK while retaining history and prior descriptors. A full key/profile change creates an independently owned current-state destination whose output and credentials are verified before cutover.
- [Encrypted history, plaintext output and conversion limits](diagrams/nvstorage-object-map.html#scenario=privacy-profile&step=1) — Encrypted current/history/deleted values, previews and diagnostics follow their profile-specific handling rules. Explicit plaintext output has a disclosed destination and scope; unsupported rich or attachment conversion preserves source data before cutover.

### Root ownership and collection transitions

Repository copy, current-note recovery export, root moves, close ordering, collection switching, and epoch-4 migration.

- [Repository copy with unavailable entries and no private store](diagrams/nvstorage-object-map.html#scenario=repository-copy&step=1) — The captured inventory includes available immutable history, descriptors and associated unknown files. Unreadable placeholders or changed captured files are reported; source Application Support is outside the repository-copy boundary.
- [Current-note recovery after local acceptance failure](diagrams/nvstorage-object-map.html#scenario=unsaved-recovery&step=1) — An admitted edit remains visible when its SQL barrier fails. Retry retains exact pending identity; a recovery export must explicitly include coherent live pending values and verify a fresh destination before source work is released.
- [Close with local work pending and provider work stalled](diagrams/nvstorage-object-map.html#scenario=quit-offline&step=1) — One close owner quiesces admission and drains complete local actions plus required private state. After local durability, Quit Without Waiting retains unpublished objects and reconcilable projection intent; derived-row failure alone does not block close.
- [Root move followed by replacement at the old pathname](diagrams/nvstorage-object-map.html#scenario=root-move&step=1) — Held authority follows the positively same directory object through a move. A new directory at the old path remains a separate target despite matching collection identity or bytes, and delayed operations revalidate their captured physical/session context.
- [Collection switch, cancellation and late completion](diagrams/nvstorage-object-map.html#scenario=collection-switch&step=1) — One transition owner settles source work and verifies the chosen destination before association cutover. Cancellation resumes only healthy admission; late callbacks retain their original session scope and cannot affect the new collection.
- [Verified migration from recovered epoch-4 state](diagrams/nvstorage-object-map.html#scenario=legacy-migration&step=1) — Migration first recovers and coherently captures legacy current values. The fresh destination must verify its complete genesis/import/snapshot, required output and credentials before association changes; failure preserves the legacy source.

## Operation traces

### Edit → local durability

Immediate edits become captured, sealed and validated input. Acceptance retains complete groups and required closure in one private transaction.

1. **Admit the edit.** The live collection accepts input immediately; exact generations track pending work. Objects: `live`, `pendinglive`.
2. **Freeze and seal once.** Capture complete meaningful actions and produce exact retryable immutable bytes. Objects: `capture`, `seal`.
3. **Establish semantic agreement.** Use the permitted checked-current basis or full declared-history validation. Objects: `decoded`, `graph`, `batch`.
4. **Commit locally.** Retain bytes, accepted membership, indexes and required closure atomically; acknowledge covered generations. Objects: `objects`, `accepted`, `pin`, `opindex`, `actionindex`.

### Private current rows → live model

Open the owned keyed store, drain startup-required work and catch up any indexed accepted suffix. A consistent complete current-row/context read supplies the live model. Invalid materialization or unfinished verification follows its separate required reconstruction/check path.

1. **Unlock and bind the store.** Recover a usable key, open the keyed container and validate selected store / bootstrap scope. Objects: `unlock`, `keychain`, `secrets`, `dbcontainer`, `header`, `localowner`.
2. **Drain required work / catch up the suffix.** Drain required Changes and prerequisites, replay unfinished verification, and bring lagging materialization to the accepted prefix. Independent optional snapshots stay queued until publication. Healthy settled startup reads no old history envelopes. Objects: `receiveq`, `recvwork`, `accepted`, `verification`, `reduce`.
3. **Capture complete current rows and context.** One consistent read captures all current bodies, compact authoring context, view epoch and represented prefix. Invalid rows or named codec data require exceptional reconstruction from retained history. Objects: `current`, `view`, `dict`.
4. **Publish the app model.** Construct all notes/search state, then recheck owner, lifecycle, view epoch and accepted/materialized prefixes before atomic host publication. Search remains synchronous. Objects: `live`, `search`, `gate`.

### Repository → accepted history

Discovery supplies candidates. Retention, prerequisites, validation and acceptance establish local history independently of arrival order.

1. **Discover and read candidates.** Rooted bounded discovery and exact reads capture candidate bytes. Objects: `rkeys`, `rchanges`, `rinitial`, `rgeneral`, `recvwork`, `rootowner`.
2. **Retain before accepting.** Durable candidate bytes and ready / wait / reject obligations survive restart. Objects: `objects`, `receiveq`.
3. **Check the complete unit.** Resolve requirements and verify protections, graph roles and complete semantic units. Objects: `decoded`, `graph`, `snapwork`, `batch`.
4. **Accept and publish locally.** Atomically accept history, advance the pin and generation-fence model publication. Objects: `accepted`, `pin`, `reduce`, `live`.

### Accepted bytes → repository

Publication copies exact locally durable objects into the repository through owned stages and checked installation.

1. **Select accepted transport input.** Capture an exact accepted prefix, retained bytes and dependency closure. Objects: `accepted`, `objects`, `pubwork`.
2. **Own a complete stage.** Entered work keeps its exact retry input and same-root physical permission. Objects: `rstages`, `rootowner`, `appleowner`.
3. **Install immutable objects.** Exclusively install and verify exact bytes with qualified file / directory barriers. Objects: `rkeys`, `rchanges`, `rinitial`, `rgeneral`.

### External file → admitted operation

Fresh observations and explicit decisions preserve external bytes before admitting an import or associated update.

1. **Observe exact source files.** Capture selected reads and fresh catalogs, including specifically disclosed Apple versions. Objects: `rnotes`, `appleversions`, `filework`.
2. **Review and retain input.** Separate latest previews, frozen admitted input and required physical relationships. Objects: `pendingwork`, `pendingdisk`, `projectiondisk`.
3. **Admit a fresh action.** Admit the reviewed import / update / recovery through ordinary durable history. Objects: `capture`, `batch`.
4. **Project accepted intent.** Capture intended output, install against fresh expected-current evidence, and retain the verified association. Objects: `live`, `projection`, `rstages`.

### Independent evidence → verified replacement

Validated surviving history and required private state form a repair union. A fresh sibling is reopened and verified before selection changes.

1. **Capture independent evidence.** Preserve exact local, repository and explicitly selected backup input with coherent required groups. Objects: `objects`, `pin`, `private`, `pendingdisk`, `projectiondisk`, `backup`, `rchanges`, `rkeys`.
2. **Prepare a verified union.** Check exact bytes, retention closure, private records and copy inventories. Objects: `repairwork`.
3. **Build and verify the sibling.** Rebuild a fresh private store and reopen it with recovery credentials. Objects: `candidate`, `selectowner`.
4. **Activate or copy explicitly.** Expected-generation selection activates the replacement; separately selected copy output preserves captured history. Objects: `selection`, `copy`, `localowner`.

## Nested object inventory

The following inventory follows the diagram hierarchy. Each object appears once; its container path distinguishes physical nesting from the labeled functional groups.

### Application process

IN MEMORY · objects live within an app / selected-store session.

#### Application live model

Application integration · authoritative during use.

##### Immediate note interaction

Synchronous input and search.

###### live — Authoritative live note collection

**In memory · value or job** · Features E, D, P, M, U.

Container / grouping path: Application process › Application live model › Immediate note interaction.

Admission updates the live store immediately. Incoming prepared changes publish atomically after final checks; admitted pending generations remain protected while history becomes durable.

- Shared current notes title/body/labels/format/dates
- Current represented revision/equal/merge inputs
- Applied operation frontier
- Automatic preservation births / independently edited conflict notes
- Temporary local Current-head/presentation pin

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [CONTEXT.md](../../CONTEXT.md), [Implementation.md](Implementation.md).

###### search — Synchronous search / live indexes

**In memory · value or job** · Features E.

Container / grouping path: Application process › Application live model › Immediate note interaction.

The complete model is initialized before editable startup. Searching and filtering run synchronously in the same input/runloop/view-refresh cycle.

- Complete current-note/search model
- UUID, label lookup and sorting structures
- Window query/filter/list selection
- Host case-insensitive label lookup distinct from exact stored label tokens

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [first-save-reopen-contract.md](plan/first-save-reopen-contract.md), [Window-UI-Architecture.md](Window-UI-Architecture.md).

###### pendinglive — Pending generations / action context

**In memory · value or job** · Features E, D, U, Q.

Container / grouping path: Application process › Application live model › Immediate note interaction.

Complete capture preserves the dependencies of newer admitted work. Exact completion clears only covered generations. Fresh editable sessions allocate new writer and action-origin context.

- Existing pending changed/deleted UUID/LSN work
- Earlier admitted pending predecessor operations/actions
- Open saved-edit group and exact before-state
- Writer epoch / sequence allocator
- Fresh independent action origin / previous-origin action

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Protocol.md](Protocol.md), [Implementation.md](Implementation.md), [swift-storage-library-proposal-v2.md](plan/swift-storage-library-proposal-v2.md).

###### views — Native undo + attached note views

**In memory · value or job** · Features E, U, Q.

Container / grouping path: Application process › Application live model › Immediate note interaction.

Views share note and undo ownership while retaining presentation state. Native undo routes through causal eligibility; durable native compensation records remaining effects through ordinary action capture.

- NSUndoManager executable groups/ranges and selections
- NativeSavedEffect / NativeCompensationStep remaining effects
- Shared live text/model owner and NSTextStorage adapter
- Generation-tagged note view attachments
- Window focus/selection/scroll/layout/geometry
- AppKit-managed marked input

Boundary: Adopted ownership/input contract; native bridge candidates and actual application integration remain distinct gates.

Sources: [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [Window-UI-Architecture.md](Window-UI-Architecture.md), [Native-Undo-Experiments.md](Native-Undo-Experiments.md).

##### Derived feature views

Queries, review and external-file intent.

###### history — History / Recently Deleted views

**In memory · value or job** · Features H, R, B.

Container / grouping path: Application process › Application live model › Derived feature views.

Indexed queries load exact retained evidence on demand. Durable restoration provenance excludes only its named source deletion, including after the restored birth is later deleted.

- HistoryQuery / Cursor / Entry / Page
- HistoryPreview / HistoricalNoteState
- Recently Deleted source-deletion entries
- Retained branch and merge previews/diff buffers
- CapturedRestoration fresh-birth command

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Protocol.md](Protocol.md), [phase3-history-validation.md](plan/phase3-history-validation.md), [restoration-record-contract.md](plan/restoration-record-contract.md), [Window-UI-Architecture.md](Window-UI-Architecture.md).

###### conflicts — Derived merges / conflict attention

**In memory · value or job** · Features M, P, H, E.

Container / grouping path: Application process › Application live model › Derived feature views.

Note predecessors determine source heads and Current. Conservative merge retains exact input/base provenance; copy disposition changes exact conflict attention. Apple member scopes remain a separate source.

- NoteReductionV1 / ReducedNoteValueV1
- DerivedMergeV1 / MergeID / DerivedStateReferenceV1
- UncoveredMaximalEdits and automatic preservation identities
- Recovery key / slot / retired deterministic identity
- Unresolved NV attention minus exact completed copies
- Invocation-scoped resolver Current and selected member previews

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Protocol.md](Protocol.md), [conservative-merge-contract.md](plan/conservative-merge-contract.md), [derived-state-reference-contract.md](plan/derived-state-reference-contract.md), [Implementation.md](Implementation.md).

###### undo — Causal Undo/Redo / reviewed commands

**In memory · value or job** · Features U, H, M, E.

Container / grouping path: Application process › Application live model › Derived feature views.

Scope-parent ancestry orders candidates, while compensation targets identify actual reversals. Preparation and admission revalidate complete commands; reviewed or automatic execution appends new ordinary captured operations/actions.

- CausalUndoSelectionV1 / UndoCandidates
- CompensationProposal / CompensationEffect
- AutomaticCompensation / CompensationReview
- Candidate frontier, selected action and affected values
- Native remaining-effect claims
- Invocation-scoped explicit approval context

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Protocol.md](Protocol.md), [swift-storage-library-proposal-v2.md](plan/swift-storage-library-proposal-v2.md), [phase3-connected-record-contract.md](plan/phase3-connected-record-contract.md).

###### projection — Active projection transition

**In memory · value or job** · Features P, D, Q, M.

Container / grouping path: Application process › Application live model › Derived feature views.

An unfinished transition retains its last accepted representation for repair matching. Settling B may advance accepted A to B while newer intended C stays pending; receipts advance after exact verification and source accounting.

- Generation-tagged accepted projection receipt
- Current intended filename/format/exact bytes
- Captured in-flight output and original expected source
- Pending source-accounting obligation
- Active projection comparison set

Boundary: Adopted contract; application/projection consumers remain Phases 6–7.

Sources: [Protocol.md](Protocol.md), [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md).

#### Prepared storage values

Portable Core / Runtime · bounded, captured inputs.

##### Capture → validate

A complete meaningful action becomes checked bytes.

###### capture — Frozen admitted action captures

**In memory · value or job** · Features E, D, U, P, Q.

Container / grouping path: Application process › Prepared storage values › Capture → validate.

The main-thread bridge freezes complete already-admitted values and semantics. Workers preserve identities and action boundaries through encoding, retry and local commit.

- CapturedActionGroup and CapturedActionIntent
- CapturedNoteGeneration UUID/LSN
- PlaintextNoteValue / NoteValueV1
- CausalParentSet and NotePredecessorSet
- Scope frontier, before/after and restoration/merge/native provenance
- DependencyLocatorTable

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [first-save-reopen-contract.md](plan/first-save-reopen-contract.md), [swift-storage-library-proposal-v2.md](plan/swift-storage-library-proposal-v2.md).

###### seal — Sealed immutable bytes / retry input

**In memory · value or job** · Features D, S, K, U.

Container / grouping path: Application process › Prepared storage values › Capture → validate.

Encoding, optional zstd and authenticated sealing fix bytes once. Retry reuses exact sealed objects and resolves ambiguous completion by committed identity.

- ObjectEnvelopeV1 exact bytes and SegmentLocator
- ImmutableRepositoryObject / Locator
- Compression and AEAD worker buffers
- OwnedCommit / CommitHandle
- SnapshotCommitHandle

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Protocol.md](Protocol.md), [Encryption.md](Encryption.md), [typed-runtime-boundaries-validation.md](plan/typed-runtime-boundaries-validation.md).

###### decoded — Bounded decoded records / claims

**In memory · value or job** · Features S, B, H, M, U, K.

Container / grouping path: Application process › Prepared storage values › Capture → validate.

Decode complete bounded records after protection checks. Computed identities and structurally valid references name evidence for subsequent semantic validation.

- HashChecked / authenticated envelope facts
- OperationRecordV1 / IdentifiedOperation
- ActionRecordV1, before/after/reference variants
- Initial/general snapshot root/page/record values
- Projection / pending / private record decodes
- ExactUTF8, labels, display dates and nominal ID wrappers

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Encryption.md](Encryption.md), [swift-storage-library-proposal-v2.md](plan/swift-storage-library-proposal-v2.md), [first-save-reopen-contract.md](plan/first-save-reopen-contract.md).

###### batch — Validated history batch + receipts

**In memory · value or job** · Features D, S, B, R, U.

Container / grouping path: Application process › Prepared storage values › Capture → validate.

Bootstrap, current-basis or full declared-history validation issues the contextual batch. The owned transaction rechecks context and commits all acceptance facts before issuing durability evidence.

- HistoryObject exact bytes with decoded contents
- ValidatedHistoryBatch issuer-private input
- AcceptedHistoryReceipt
- AcceptedSnapshotReceipt
- Exact covered-generation commit outcome

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [swift-storage-library-proposal-v2.md](plan/swift-storage-library-proposal-v2.md), [typed-runtime-boundaries-validation.md](plan/typed-runtime-boundaries-validation.md), [phase4-snapshot-acceptance-validation.md](plan/phase4-snapshot-acceptance-validation.md).

##### Query → reconstruct

Checked history produces views and snapshots.

###### graph — Checked history / query evidence

**In memory · value or job** · Features B, H, M, U, R, D.

Container / grouping path: Application process › Prepared storage values › Query → reconstruct.

Indexed bounded reads and one-decode-per-envelope traversal verify complete membership/links. Scoped query evidence retains its checked owner/session/prefix/view/scope; full graph evidence serves reconstruction and collection commands.

- CheckedHistoryTraversal / CheckedGraphRows
- CheckedEnvelopeRecords
- Operation causal ancestry and note-predecessor graph
- Action origin/scope/compensation/native-coverage graph
- Current/context capture, exact occurrence coverage
- CheckedCurrentBasis for qualifying ordinary saves

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [swift-storage-library-proposal-v2.md](plan/swift-storage-library-proposal-v2.md), [at-most-once-envelope-decoding.md](plan/phase-4-improvements/at-most-once-envelope-decoding.md), [startup-and-scoped-queries.md](plan/phase-4-improvements/startup-and-scoped-queries.md).

###### reduce — Prepared reduction / reconstruction

**In memory · value or job** · Features B, E, M, U, R.

Container / grouping path: Application process › Prepared storage values › Query → reconstruct.

Reduction runs detached from live editing and SQL writes. Installation rechecks complete starting view and accepted target; final host publication independently checks live context.

- PreparedModelChange
- PreparedReconstruction / recovery basis
- Affected CurrentNoteCellV1 rows
- AuthoringContextV1
- StoreSnapshot checked complete capture
- One-shot opening handoff

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [phase4-bootstrap-reconstruction-plan.md](plan/phase4-bootstrap-reconstruction-plan.md), [swift-storage-library-proposal-v2.md](plan/swift-storage-library-proposal-v2.md).

###### snapwork — Snapshot capture / assembly evidence

**In memory · value or job** · Features B, S, R, H, U.

Container / grouping path: Application process › Prepared storage values › Query → reconstruct.

Incremental construction emits bounded envelopes. Assembly verifies complete page tree/counts/digest; semantic verification checks the stated history, while retention-parent checks cover exact accepted object closures.

- InitialCollectionV1 / BootstrapCandidate
- InitialBootstrapValidationV1 / scope-frontier facts
- GeneralSnapshotCapture / PreviewV1
- VerifiedGeneralSnapshotClaims
- CheckedRetentionParents / CheckedSnapshotAcceptance
- Page-stream readers, hashing and owned sink buffers

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [general-snapshot-record-contract.md](plan/general-snapshot-record-contract.md), [phase4-bootstrap-reconstruction-plan.md](plan/phase4-bootstrap-reconstruction-plan.md).

###### maintenance — Recoding / maintenance job state

**In memory · value or job** · Features B, R, Q, D.

Container / grouping path: Application process › Prepared storage values › Query → reconstruct.

Explicit bounded recoding rechecks exact view/physical inputs; optional compaction settles completion or rollback before releasing resources. Automatic training/recoding/VACUUM and physical read-ahead hints retain independent gates.

- EncodedCurrentRows preparation
- Captured logical/physical current rows
- Per-session training-attempt marker
- MaintenanceState and unique cancellation identity
- VacuumBudget / VacuumOutcome

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [private-current-row-codec.md](plan/private-current-row-codec.md), [phase4-current-row-locality-maintenance-plan.md](plan/phase4-current-row-locality-maintenance-plan.md).

#### Sessions and external work

Resources fence effects; jobs carry captured evidence.

##### Live session resources

Owners, permissions, keys and generations.

###### localowner — Local store / database owner

**In memory · revocable owner/context** · Features D, B, U, R, Q.

Container / grouping path: Application process › Sessions and external work › Live session resources.

One owner serializes synchronous SQL turns and reserves work before suspension. Separate worker preparation and provider resources preserve opportunities for local durability.

- Exclusive private-directory owner/lease
- Database / DatabaseLane and keyed connection
- StorageExecutor, HistoryWorker, CommandWorker
- LocalStoreLifecycle / LocalCommitState / OwnedCommit
- ReceiveWorkState and completion waiters
- Borrowed statement/C resources with scoped final disposal
- SQLite pager cache and keyed connections
- Fixed-cut SQLite backup connection and job ownership

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [swift-storage-library-proposal-v2.md](plan/swift-storage-library-proposal-v2.md), [actor-database-adoption.md](plan/actor-database-adoption.md), [LocalStore.md](LocalStore.md).

###### rootowner — Physical repository root owner

**In memory · revocable owner/context** · Features S, P, R, Q.

Container / grouping path: Application process › Sessions and external work › Live session resources.

Positive same-root continuity permits physical operations and survives moves. Root/lifecycle checks bracket blocking effects; quiesce retains ownership until entered work settles.

- Held directory descriptors / nonblocking flock
- Local identity, loss-event resource and latched loss
- RepositoryRootPermission session/generation
- Nested enumeration streams and cleanup ownership
- Entered operation reservation and rooted ancestor handles

Boundary: Root ownership and coordinated effects have recorded platform qualification. Continuously owned HFS+ roots support tested deep moves/reads; fresh acquisition at a deep HFS+ path has the approved ESTALE capability-refusal limit. The P5.4 ledger records exact tested bounds.

Sources: [01-root-ownership-and-execution.md](plan/phase5/01-root-ownership-and-execution.md), [02-immutable-files-and-namespace.md](plan/phase5/02-immutable-files-and-namespace.md), [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [04-apple-coordination-and-discovery-validation.md](plan/phase5/04-apple-coordination-and-discovery-validation.md).

###### appleowner — Apple coordination / provider observations

**In memory · revocable owner/context** · Features S, P, Q, B.

Container / grouping path: Application process › Sessions and external work › Live session resources.

Rooted I/O stays inside the actual accessor interval. Callbacks request fresh observation; entered accessors retain owned resources through delayed completion, cancellation and close.

- NSFileCoordinator actual accessor context
- One root NSFilePresenter / exactly-once relinquishment replies
- Bookmark / candidate root observations
- Vnode/FSEvents invalidation hints
- Materialization requests and copied availability/upload status
- Opaque provider identity / visibility witnesses

Boundary: P5.4 A–F is implemented and qualified within the ledger’s platform/capability limits, including the automatic driver and final-source signed two-Mac exchange. Application integration, distribution signing and physical power-loss qualification retain their separate gates.

Sources: [04-apple-coordination-and-discovery.md](plan/phase5/04-apple-coordination-and-discovery.md), [Apple-API-Contract-Validation.md](../Apple-API-Contract-Validation.md), [04-apple-coordination-and-discovery-validation.md](plan/phase5/04-apple-coordination-and-discovery-validation.md).

###### selectowner — Selection / transition ownership

**In memory · revocable owner/context** · Features B, R, K, Q.

Container / grouping path: Application process › Sessions and external work › Live session resources.

A verified candidate and durable unlocking route precede selected-store activation. Fresh physical selection/association supplies new authority after recovery or a requested root switch.

- SelectionLease and expected SelectedStoreState
- LocalStoreSelection / adapter-validated association
- Verified replacement/activation consumption
- Fresh store/session/writer/origin context
- Independent add-only credential provisioning/readback

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [phase4-private-state-repair-copy-plan.md](plan/phase4-private-state-repair-copy-plan.md), [05-startup-and-root-reassociation.md](plan/phase5/05-startup-and-root-reassociation.md).

###### gate — Admission / publication / close fences

**In memory · revocable owner/context** · Features E, D, B, S, P, U, Q, R, K.

Container / grouping path: Application process › Sessions and external work › Live session resources.

Final consumers revalidate captured applicability. Quit forces admitted history and private-state barriers before optional provider waiting, fences/drains callbacks, and releases ownership last.

- Edit-admission gate independent local-health/startup/lock/lifecycle reasons
- Store incarnation, root/lifecycle/structural/note generations
- Final synchronous model-publication callback
- Quit/folder-switch quiesce, forced capture and drain
- Projection deferral / captured upload wait
- Operation-specific completion ownership

Boundary: Runtime ownership/publication fences exist within headless scope; final app quit/folder-switch orchestration remains Phase 7.

Sources: [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [Implementation.md](Implementation.md), [swift-storage-library-proposal-v2.md](plan/swift-storage-library-proposal-v2.md).

###### secrets — Unlock context / transient crypto state

**In memory · value or job** · Features K, B, D, S, R.

Container / grouping path: Application process › Sessions and external work › Live session resources.

Validated descriptors or optional Keychain input unlock a pinned context. Authenticate encrypted provider bytes before decompression/decoding; password-free SQLCipher uses the documented public key.

- User password / encryption recovery key input
- Unwrapped CK and CollectionKeyID
- Pinned bootstrap/profile/protection context
- Domain-separated HKDF object and SQLCipher keys
- Argon2id wrapping key
- Nonce, bounded byte cursor, zstd/AEAD working buffers
- Prepared per-job dictionaries

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Encryption.md](Encryption.md), [LocalStore.md](LocalStore.md), [swift-storage-library-proposal-v2.md](plan/swift-storage-library-proposal-v2.md).

##### External operation values

Discovery, transport, file review and repair.

###### recvwork — Receive / discovery turn

**In memory · value or job** · Features S, B, Q.

Container / grouping path: Application process › Sessions and external work › External operation values.

Discovery copies rooted observations, checks bounded hints and hands unknown exact bytes into durable receive. Preparation yields between turns; missing/rejected prerequisites keep their separate classifications.

- ObjectRequirement.retainedBytes / acceptedHistory
- PreparedCandidate and rejection/blocker diagnostics
- Single receive reservation and save-settlement waiters
- RepositoryDiscoveryTurn / Outcome
- Single-use nested directory stream/cursor stack
- RepositoryEntryObservation metadata batches
- RepositoryHintLookup ordered answers

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [03-local-repository-exchange.md](plan/phase5/03-local-repository-exchange.md), [bounded-discovery-batches-plan.md](plan/phase5/bounded-discovery-batches-plan.md).

###### pubwork — Publication batch / installation evidence

**In memory · value or job** · Features S, D, R, Q.

Container / grouping path: Application process › Sessions and external work › External operation values.

Bounded publication captures accepted exact objects and releases SQL turns before root effects. Physical installation evidence is checked against the captured batch and live root; later upload remains advisory.

- RepositoryPublicationBatch / Cursor
- ImmutableInstallation
- PublishedRepositoryBatch
- RepositoryInstallationFailure installed/uncertain/stage accounting
- Exact accepted-dependency lookup

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [03-local-repository-exchange-validation.md](plan/phase5/03-local-repository-exchange-validation.md), [02-immutable-files-validation.md](plan/phase5/02-immutable-files-validation.md).

###### filework — File observations / projection plans

**In memory · value or job** · Features P, M, S, Q.

Container / grouping path: Application process › Sessions and external work › External operation values.

Current-file reconciliation captures catalogs, exact selected bytes and model generations, then revalidates before publication or physical effects. Immutable-object discovery uses its own bounded namespace path.

- Rooted FileObservation and filesystem identity
- Provider catalog token / visibility witness
- Coordinated before/after shallow catalogs
- ProjectionDescriptor / NVProjectionStampV1
- ExpectedProjectionReplacement / external-delete plan
- Exact body/mandatory-metadata readback

Boundary: Adopted plaintext/Apple contracts; production projection/application integration remains Phases 6–7.

Sources: [Protocol.md](Protocol.md), [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [Foundation-Safe-Replacement-Migration.md](../Foundation-Safe-Replacement-Migration.md).

###### pendingwork — Pending-file preview / decision capture

**In memory · value or job** · Features P, M, D, R.

Container / grouping path: Application process › Sessions and external work › External operation values.

Classification and targeted review use one note’s active path/bytes. Reservations preserve retry identity; fresh decisions/generation checks admit complete captures, and exact committed evidence later settles references.

- PendingItemState / PendingReservationRecovery
- PreparedPendingAction / PendingAdmissionBinding
- PendingAssociationPreparation
- Plausible repair-candidate comparison frame
- Operation reservation / frozen pending input
- Provisional relationship claim and current content review

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Protocol.md](Protocol.md), [private-record-contract.md](plan/private-record-contract.md), [phase4-private-state-repair-copy-validation.md](plan/phase4-private-state-repair-copy-validation.md).

###### repairwork — Repair / backup / copy evidence

**In memory · value or job** · Features R, B, D, K, Q.

Container / grouping path: Application process › Sessions and external work › External operation values.

Repair combines independently valid exact objects and preserves unique private records. Copy/backup outcomes report their captured coverage; activation consumes separately issued verified replacement context.

- PrivateRepairEvidence / PartialPrivateSalvage
- CompletePrivateBackup capture
- VerifiedReplacement / VerifiedActivationInput
- Repair union exact object/descriptor inventory
- RepositoryByteRequirement / CopiedRepositoryFile
- RepositoryCopyResult / issues
- Transient pending/reference/dictionary fingerprints

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [phase4-private-state-repair-copy-plan.md](plan/phase4-private-state-repair-copy-plan.md), [06-repair-replacement-and-copy.md](plan/phase5/06-repair-replacement-and-copy.md).

### Private storage · Collections/

ON DISK · one selected store; replacement candidates have separate identities.

#### selection — Selected-store record

**On disk · required private** · Features B, R, Q.

Container / grouping path: Private storage · Collections/.

Expected-generation durable replacement chooses the verified private-store candidate. Its locator is revalidated under ownership when opening.

- SelectedStoreRecordV1
- AssociationID
- Selected LocalStoreID
- Selection generation and checksum

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [phase4-private-state-repair-copy-plan.md](plan/phase4-private-state-repair-copy-plan.md).

#### candidate — Fresh private-store candidate

**On disk · required private** · Features B, D, R, K.

Container / grouping path: Private storage · Collections/.

Repair reconstructs a new store, retains complete required history/pin/private records, reopens it with recovery credentials, then activates it through the selected-store record.

- Fresh keyed Collection.sqlite and sidecars
- Rebuilt acceptance indexes and current rows
- Validated private groups and pending links
- Fresh unlock descriptors

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [06-repair-replacement-and-copy.md](plan/phase5/06-repair-replacement-and-copy.md).

#### Selected <LocalStoreID> directory

The active private store owns its database and unlock copies.

##### unlock — Private unlock descriptors

**On disk · required private** · Features K, B, R.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory.

These nonsecret descriptors sit outside SQLCipher so a password can recover CK before opening the database. Private backups include usable copies.

- Bounded immutable wrapped-key descriptor files
- Content-hash filenames
- Same-CK password rewrap routes

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [Encryption.md](Encryption.md).

##### Database files

One private durable container per LocalStoreID.

###### dbcontainer — Private database + pager files

**On disk · required private** · Features D, B, R, K, Q.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory.

One private database file contains retained history, required private state, indexes and rebuildable current rows. Qualified commit supplies local durability; sibling pager files follow SQLite recovery and backup ownership.

- SQLCipher encrypted database pages for both profiles
- SQLite-owned WAL/SHM or rollback journal

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [sqlite-local-schema.md](plan/sqlite-local-schema.md).

###### Collection.sqlite

One keyed SQLCipher file · all 27 production SQL tables.

###### History and materialization

Stored authority and its derived current view.

###### Accepted and retained history

Exact bytes, accepted membership and query indexes.

###### objects — Exact retained object BLOBs

**On disk · required private** · Features D, S, B, H, U, R, K.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › History and materialization › Accepted and retained history.

One row retains exact immutable bytes under their checked identity. Retention and accepted-history membership have distinct roles; accepted/sealed history stays retained in v1.

- Sealed Changes envelopes
- Initial/general snapshot root/page envelopes
- Exact descriptor bytes
- Unaccepted parked/rejected incoming objects

SQL tables: `objects`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [sqlite-local-schema.md](plan/sqlite-local-schema.md), [LocalStore.md](LocalStore.md).

###### accepted — Acceptance batches + dependencies

**On disk · required private** · Features D, S, B, R, Q.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › History and materialization › Accepted and retained history.

A single qualified transaction joins full validation, exact object retention, complete membership/edges, pin advancement, wakeups and exact pending-operation links. Local sequences drive indexed suffix catch-up.

- acceptance_batches
- accepted_objects
- accepted_dependencies
- Accepted prefix and object-evidence frontier

SQL tables: `acceptance_batches`, `accepted_objects`, `accepted_dependencies`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [sqlite-local-schema.md](plan/sqlite-local-schema.md), [LocalStore.md](LocalStore.md).

###### opindex — Operation / note relationship indexes

**On disk · accepted-history index** · Features D, B, H, M, U, R.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › History and materialization › Accepted and retained history.

Indexes locate canonical logical operations in exact accepted envelopes. Causal parents describe observed history; note predecessors determine heads and supersession.

- operations and operation_occurrences
- operation_parents causal graph
- note_predecessors supersession graph
- Per-birth and logical-Delete listing indexes

SQL tables: `operations`, `operation_occurrences`, `operation_parents`, `note_predecessors`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [sqlite-local-schema.md](plan/sqlite-local-schema.md), [Protocol.md](Protocol.md).

###### actionindex — Action / restoration indexes

**On disk · accepted-history index** · Features D, H, U, M, B, R.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › History and materialization › Accepted and retained history.

Complete actions retain before/after, scope/origin, compensation/native coverage and restoration provenance. Derived restoration/copy lookup indexes accelerate listing and commands.

- actions and action_occurrences
- action_members
- action_scope_parents
- Origin/predecessor and scope indexes
- Conflict-copy partial index
- restorations source-deletion → first durable restoration

SQL tables: `actions`, `action_occurrences`, `action_members`, `action_scope_parents`, `restorations`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [sqlite-local-schema.md](plan/sqlite-local-schema.md), [restoration-record-contract.md](plan/restoration-record-contract.md), [Protocol.md](Protocol.md).

###### Rebuildable current view

Startup acceleration from an exact accepted prefix.

###### current — Derived current-note cells

**On disk · rebuildable** · Features E, B, M, U, P.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › History and materialization › Rebuildable current view.

Cells represent one exact accepted prefix for startup and ordinary authoring. Current heads and represented inputs remain explicit even when note bodies compare equal.

- Complete current NoteValue title/body/labels/dates/format
- Representative occurrence and represented revisions
- All note heads and note scope frontier
- Equal/merge descriptor
- Automatic source and deterministic conflict identity
- CurrentRowFrameV1 raw/zstd/dictionary payload

SQL tables: `current_notes`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [sqlite-local-schema.md](plan/sqlite-local-schema.md), [phase3-connected-record-contract.md](plan/phase3-connected-record-contract.md).

###### view — View epoch + authoring context

**On disk · rebuildable** · Features E, B, U, D.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › History and materialization › Rebuildable current view.

Rows, global context and prefix advance in one guarded materialization transaction. New epoch/prefix and final host generations fence stale reconstruction or startup output.

- Reducer version
- Fresh view epoch
- Materialized local acceptance prefix
- Global operation frontier
- Collection-scoped action frontier

SQL tables: `view_meta`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [sqlite-local-schema.md](plan/sqlite-local-schema.md).

###### dict — Private current-row dictionaries

**On disk · rebuildable** · Features B, R, K.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › History and materialization › Rebuildable current view.

Training/recoding installs dictionaries with referencing rows atomically. Missing or invalid named dictionaries require complete materialization rebuild from healthy history.

- CurrentRowDictionaryV1 formatted dictionary bytes
- Mixed dictionary generations
- Per-job bounded prepared ZSTD dictionaries

SQL tables: `current_dictionaries`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [private-current-row-codec.md](plan/private-current-row-codec.md), [LocalStore.md](LocalStore.md).

###### hints — Accepted-file scan hints

**On disk · rebuildable** · Features S, B.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › History and materialization › Rebuildable current view.

Fresh rooted observations plus exact accepted membership allow unchanged-body reuse across ordinary reopen. Each hint remains acceleration advice with separately checked session permissions.

- Protocol-relative path key
- Kind/device/inode/size/link count/mtime/ctime fingerprint
- Exact accepted-object ID and hint codec

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Protocol.md](Protocol.md), [bounded-discovery-batches-plan.md](plan/phase5/bounded-discovery-batches-plan.md), [03-local-repository-exchange-validation.md](plan/phase5/03-local-repository-exchange-validation.md).

###### Required local state

Pins, restart obligations and private relationships.

###### header — Store header / scope binding

**On disk · required private** · Features B, D, K, R.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › Required local state.

Opening compares the required header with independently selected ownership/association and validated unlock context.

- LocalStoreID and CollectionID
- Profile/key/codec/schema versions
- Bootstrap descriptor and genesis binding

SQL tables: `store_header`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [sqlite-local-schema.md](plan/sqlite-local-schema.md), [LocalStore.md](LocalStore.md).

###### pin — Required retained-history pin

**On disk · required private** · Features D, B, S, R, Q.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › Required local state.

Acceptance advances the pin atomically. Surviving locators expose loss of previously accepted evidence independently of valid current rows; all ancestor bytes remain retained.

- Full required SegmentLocator frontier
- Required descriptor identities
- Validated snapshot retention-parent coverage

SQL tables: `retained_frontier`, `retained_descriptors`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [sqlite-local-schema.md](plan/sqlite-local-schema.md), [LocalStore.md](LocalStore.md).

###### receiveq — Durable receive work

**On disk · required private** · Features S, B, D, Q.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › Required local state.

Arrival/acceptance wakes dependents transactionally. Parking rechecks requirements; rejection settles only the checked candidate. Startup selects required Changes/prerequisites before optional snapshots.

- Unique ready candidates
- Reverse prerequisite-ID waits
- Versioned candidate-local rejection reason
- Retained blocked descendants and restart obligations

SQL tables: `ready_objects`, `object_waits`, `rejected_objects`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [sqlite-local-schema.md](plan/sqlite-local-schema.md), [phase4-received-snapshot-validation.md](plan/phase4-received-snapshot-validation.md).

###### private — Required private record groups

**On disk · required private** · Features B, P, K, R, Q.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › Required local state.

Generation-checked groups preserve host-private settings and association independently of derived rows. Physical receipts remain historical observations requiring fresh checks after restart.

- Versioned collection settings, font/color/extension overrides
- Remembered per-note UTF-16 cursor ranges
- LocalAssociationV1 bookmark/scope bytes
- Selected initial-root bootstrap group

SQL tables: `private_groups`.

Boundary: Core private record roles exist; platform preference/receipt interpretation and projection adapters retain separate gates.

Sources: [private-record-contract.md](plan/private-record-contract.md), [LocalStore.md](LocalStore.md), [Protocol.md](Protocol.md).

###### verification — Verification obligations + damage marker

**On disk · required private** · Features D, B, H, U, R, Q.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › Required local state.

Commit a request before protected checks and retain it through final semantic verification. Success settles that exact request; discovered damage fences publication and replaces the request atomically.

- Exact-object, accepted-prefix and bootstrap verification recipes
- Bound store/collection/descriptor context
- Persistent known-history-damage marker

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [durable-verification-recovery.md](plan/phase-4-improvements/durable-verification-recovery.md), [sqlite-local-schema.md](plan/sqlite-local-schema.md).

###### pendingdisk — Pending-file recovery reference graph

**On disk · required private** · Features P, D, R, Q.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › Required local state.

One latest verified preview and exact admitted frozen inputs survive crashes. Payload/reference switches and settlement transfer are transactional; release requires every owner to be gone.

- pending_payloads immutable source snapshot BLOBs
- pending_items latest reference/generation/classification
- pending_reservations exact birth/action/nonce/Current binding
- pending_settlements committed observation/operation links

SQL tables: `pending_payloads`, `pending_items`, `pending_reservations`, `pending_settlements`.

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [private-record-contract.md](plan/private-record-contract.md), [Protocol.md](Protocol.md), [sqlite-local-schema.md](plan/sqlite-local-schema.md).

###### projectiondisk — Required projection relationship state

**On disk · required private** · Features P, D, R, Q.

Container / grouping path: Private storage · Collections/ › Selected <LocalStoreID> directory › Database files › Collection.sqlite › Required local state.

Required Local State preserves physical relationship observations independently of derived current rows. Reconciliation revalidates observed files and derives current intent from accepted history. Concrete projection/publication tables belong to their actual adapter increment.

- Generation-tagged last verified projection association
- Captured source observation and receipt
- Unfinished save/rename/format source-accounting evidence
- Settled external observation and exact operation linkage

Boundary: Adopted logical role; physical projection table/adapter contract remains Phase 6 work.

Sources: [Protocol.md](Protocol.md), [sqlite-local-schema.md](plan/sqlite-local-schema.md), [06-repair-replacement-and-copy.md](plan/phase5/06-repair-replacement-and-copy.md).

### Repository and provider evidence

Files and external observations remain separate authorities.

### Selected repository folder

ON DISK · physical root identity is held independently of collection identity.

#### rdirs — Repository directory objects

**Persistent · external / OS / output** · Features S, P, R, Q.

Container / grouping path: Repository and provider evidence.

The physical directory tree contains protocol objects and plaintext files. Held/named ancestor checks and add-only directory creation preserve competing occupants; collection identity and physical root identity retain separate roles.

- Selected physical repository folder
- Visible ordinary NV Data directory
- Version, keys and segments directories
- Writer-epoch subdirectories
- Rooted directory identities and namespace entries

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [02-immutable-files-and-namespace.md](plan/phase5/02-immutable-files-and-namespace.md).

#### NV Data/ → v1/

Visible ordinary protocol directory.

##### keys/

Bootstrap and unlocking descriptors.

###### rkeys — Bootstrap / key descriptors

**On disk · portable immutable** · Features S, B, K, R.

Container / grouping path: Repository and provider evidence › Selected repository folder › NV Data/ → v1/ › keys/.

An immutable descriptor anchors bootstrap and unlocking. Same-key password changes add a descriptor while preserving old routes.

- Public or wrapped BootstrapDescriptorV1
- Collection/profile/key/codec binding
- Genesis segment locator
- Argon2id salt/profile and wrapped CK for encrypted mode

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Encryption.md](Encryption.md), [first-save-reopen-contract.md](plan/first-save-reopen-contract.md).

##### segments/<writerEpoch>/

One immutable-object namespace · roots and pages use ordinary .nvseg leaves.

###### rchanges — Changes segment files

**On disk · portable immutable** · Features D, S, H, M, U, R.

Container / grouping path: Repository and provider evidence › Selected repository folder › NV Data/ → v1/ › segments/<writerEpoch>/.

Exact sealed provider files transport complete immutable groups. Operation kinds include Genesis, ImportComplete, Create/Import, Put, Delete, RecoverCopy, RetireConflict and AdoptAutomatic.

- ObjectEnvelopeV1 Changes kind
- ChangesPayloadV1 dependency-locator table
- OperationRecordV1
- ActionRecordV1
- Projection/merge/restoration/compensation subrecords

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Protocol.md](Protocol.md), [Encryption.md](Encryption.md), [phase3-connected-record-contract.md](plan/phase3-connected-record-contract.md).

###### Snapshot representations

Logical families in the same segment namespace.

###### rinitial — Initial snapshot root + pages

**On disk · portable immutable** · Features B, S, R.

Container / grouping path: Repository and provider evidence › Selected repository folder › NV Data/ → v1/ › segments/<writerEpoch>/ › Snapshot representations.

The initial root/pages bind the complete imported note set to its retained operations/actions. A complete preview and editable bootstrap have separate evidence requirements.

- InitialSnapshotRootV1 flat page list
- InitialSnapshotPageV1 complete note rows
- Genesis count/value digest
- ImportComplete operation frontier
- Exact initial history locators

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Protocol.md](Protocol.md), [first-save-reopen-contract.md](plan/first-save-reopen-contract.md).

###### rgeneral — General snapshot root + tree

**On disk · portable immutable** · Features B, S, H, M, U, R.

Container / grouping path: Repository and provider evidence › Selected repository folder › NV Data/ → v1/ › segments/<writerEpoch>/ › Snapshot representations.

Snapshots preserve seven logical state classes at a stated operation cut; their eighth v1 category independently covers accepted snapshot-object closures. Reconstruction unions all accepted outside-cut operations while retaining every ancestor byte.

- GeneralSnapshotRootV1: 236-byte root with eight category counts
- GeneralSnapshotPageV1 index/data ranges
- Canonical paged state stream
- Current cells, operation frontier, action-scope maxima
- Deletes, retirements, copied-source dispositions, restorations
- Tag 8 exact retention-parent locators; zero count when empty

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [general-snapshot-record-contract.md](plan/general-snapshot-record-contract.md), [LocalStore.md](LocalStore.md), [snapshot-retention-coverage.md](plan/phase-4-improvements/snapshot-retention-coverage.md).

#### Other owned root files

Projection and install / replacement work.

##### rnotes — Plaintext note projections

**Persistent · external / OS / output** · Features P, S, M, R.

Container / grouping path: Repository and provider evidence › Selected repository folder › Other owned root files.

Files are interoperable current inputs/outputs. Advisory stamps name represented history and exact projected bytes; physical association uses fresh observations and the current-file decision matrix.

- Separate note file exact encoded bytes and mandatory metadata
- NVProjectionStampV1 in org.notationalvelocity.projection#S
- Revision/equal/merge or automatic-source reference
- Unknown ordinary external files

Boundary: Adopted projection contract; production projection/application consumers remain Phases 6–7.

Sources: [Protocol.md](Protocol.md), [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [Foundation-Safe-Replacement-Migration.md](../Foundation-Safe-Replacement-Migration.md).

##### rstages — Owned stages / preserved displacement

**Persistent · external / OS / output** · Features S, P, R, Q, K.

Container / grouping path: Repository and provider evidence › Selected repository folder › Other owned root files.

Exclusive immutable installation verifies complete stages and final bytes with file/nested-directory barriers. Mutable replacement preserves displaced evidence through its separately qualified caller contract.

- Operation-owned immutable-install stage at held root
- Same-volume mutable-file replacement stage
- Preserved displaced file/backup
- Uncertain or cleanup-failed artifacts
- Foreign protocol-name occupants

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [02-immutable-files-validation.md](plan/phase5/02-immutable-files-validation.md), [06-repair-replacement-and-copy.md](plan/phase5/06-repair-replacement-and-copy.md), [Foundation-Safe-Replacement-Migration.md](../Foundation-Safe-Replacement-Migration.md).

### Provider-managed external evidence

Associated with selected files · OS-managed lifetime.

#### appleversions — Apple-disclosed unresolved versions

**Persistent · external / OS / output** · Features P, M, Q.

Container / grouping path: Repository and provider evidence › Provider-managed external evidence.

Explicit resolver requests copy selected unresolved bodies. Apple disposition requires exact local note/action durability and verified plaintext installation for its captured member scope.

- NSFileVersion selected unresolved member
- Captured version URL/body
- Member-specific resolved disposition

Boundary: OS-managed source; actual Apple/segment/projection integration remains a release gate.

Sources: [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [Apple-API-Contract-Validation.md](../Apple-API-Contract-Validation.md), [Implementation.md](Implementation.md).

### Other locations and services

PERSISTENT · separately selected destinations or OS-owned state.

#### OS / application services

Device and application scope.

##### keychain — Optional remembered key

**Persistent · external / OS / output** · Features K, B, Q.

Container / grouping path: Other locations and services › OS / application services.

Remember on this Mac caches the encrypted collection key after add-only provisioning and readback. Password/recovery-key unlocking remains independently usable.

- Device-bound generic-password item holding CK
- Complete service/account/access-group identity
- Local remember-unlock preference

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Encryption.md](Encryption.md), [LocalStore.md](LocalStore.md).

##### hostprefs — Application-global preferences

**Persistent · external / OS / output** · Features E, B, Q.

Container / grouping path: Other locations and services › OS / application services.

The existing host preference owner preserves application-global defaults. Collection-specific settings and remembered note cursor ranges have independently versioned private SQL records.

- GlobalPrefs application defaults
- Application-owned window/search presentation preferences
- Explicitly mapped collection overrides

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [private-record-contract.md](plan/private-record-contract.md), [Window-UI-Architecture.md](Window-UI-Architecture.md).

#### Preserved recovery evidence

Independent, explicitly qualified recovery input.

##### backup — Private backup / preserved evidence

**On disk · required private** · Features D, R, K, Q.

Container / grouping path: Other locations and services › Preserved recovery evidence.

A fixed-cut keyed SQLite backup preserves accepted history, required state and pending references. Repair preserves originals and salvages candidates on a working copy.

- CompletePrivateBackup destination
- Preserved original database and WAL/rollback journal
- Journal-recovered working copy
- Quarantined partial salvage and displaced evidence

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [LocalStore.md](LocalStore.md), [phase4-private-state-repair-copy-validation.md](plan/phase4-private-state-repair-copy-validation.md).

#### Import and output destinations

Explicitly selected stores or files.

##### legacy — Legacy collection / explicit export

**Persistent · external / OS / output** · Features B, R.

Container / grouping path: Other locations and services › Import and output destinations.

Opening/recovery retains the legacy path. Migration captures complete source values; explicit epoch-4 export writes current values to its separately selected destination.

- Notes & Settings epoch-4 archive
- Interim Note-Changes legacy recovery evidence
- Legacy credentials and settings import

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [first-save-reopen-contract.md](plan/first-save-reopen-contract.md).

##### copy — Repository copy / new destination

**Persistent · external / OS / output** · Features R, S, K.

Container / grouping path: Other locations and services › Import and output destinations.

Repository copy preserves exact bytes and collection/birth/operation/action identities. Active-session saved-work copy additionally includes the captured durable local union.

- Copied descriptors and every available immutable object
- Associated plaintext files
- Unknown/unimported repository entries
- Captured copy inventory and reported holes

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md), [Protocol.md](Protocol.md), [06-repair-replacement-and-copy.md](plan/phase5/06-repair-replacement-and-copy.md).

##### scratch — Explicit plaintext scratch / export

**Persistent · external / OS / output** · Features P, R, K, Q.

Container / grouping path: Other locations and services › Import and output destinations.

Explicit external editing uses owned scratch outside an encrypted provider root. Current-state export or key/profile conversion captures coherent current values into a fresh destination.

- External-editor scratch file and handoff
- Explicit plaintext/current-notes export
- Fresh-genesis profile/key conversion destination
- Legacy export output

Boundary: Adopted design; implementation scope is documented by the cited plans.

Sources: [Encryption.md](Encryption.md), [Implementation.md](Implementation.md), [swift-storage-implementation-plan.md](plan/swift-storage-implementation-plan.md).

## Earlier alternatives and deferred objects

| Object family | Current disposition | Reason / source |
| --- | --- | --- |
| Packed startup cache / StartupCacheV1 / startup_cache / view_changes | Removed | Current-note rows and compact context are the adopted startup representation. [LocalStore.md](LocalStore.md) |
| Separate NVLOC1 / NVLST1 state files and nested private object envelopes | Superseded | Private required-state records live in keyed SQL pages; exact unlock descriptors and selected-store record remain outside. [first-save-reopen-contract.md](plan/first-save-reopen-contract.md) |
| Modern application WAL, mutable shared HEAD, shared undo cursor, provider receipt/membership registry, lock child | Excluded | Immutable segments, causal action history, owned directory descriptors and atomic private acceptance supply their respective roles. [Protocol.md](Protocol.md) |
| Physical page-list/read-ahead hint file | Deferred candidate | Disposable physical I/O advice was investigated; it is omitted from the implemented 4F increment. [private-current-row-codec.md](plan/private-current-row-codec.md) |
| Co-add occupancy/path-slot identity | Deferred / disabled | Ordinary imports use fresh births. Experiments do not enable deterministic co-add identity. [Protocol.md](Protocol.md) |
| Encrypted per-note projections / continuous plaintext mirror / full-history search / named restore points / permanent erase | Deferred or outside v1 | These are outside the adopted initial feature set; explicit scratch/export and retained history are represented above. [README.md](README.md) |
| Durable marked-text draft / serialized NSUndoManager continuation | Unadopted | AppKit owns provisional input and native executable undo stays transient; retained meaningful actions supply portable compensation. [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md) |
| Rich RTF/HTML codec expansion | Paused design work | New format work is plaintext-first; legacy supported content retains preservation or explicit unsupported/conversion handling. [iCloud-Drive-Support-Spec.md](../iCloud-Drive-Support-Spec.md) |

## Regeneration and consistency checks

The renderer validates object/edge IDs, feature references, source paths, connectivity, unique hierarchy placement, lifetime boundaries, trace references, and complete one-owner mapping of the production SQL tables. Scenario checks resolve actual Markdown headings and requirement/test rows, validate every object/operation/related-story reference, and require scenario coverage of the full normative requirement registry. The hierarchy, SVG and HTML share one geometry. `--check` compares all six saved artifacts with freshly rendered content and reports stale or missing outputs without writing files. Generation uses Node built-ins; the saved HTML/SVG are standalone and use embedded resources. From the repository root:

```sh
node docs/impl-proposal-5/diagrams/render-object-map.mjs
node docs/impl-proposal-5/diagrams/render-object-map.mjs --check
```

Edit `nvstorage-object-map.json` for records/relationships, `nvstorage-object-map.layout.json` for nesting/display/traces, and `nvstorage-scenarios.json` for scenario cards/steps/evidence. `scenario-catalog.mjs` validates and resolves their evidence links. `nested-object-map.mjs` renders the shared geometry; `object-map-viewer.js` and `.css` supply embedded controls. The [DOT export](diagrams/nvstorage-object-map.dot) retains the hierarchy and all relationships for external tooling. Product/model verification remains governed by the cited contracts.
