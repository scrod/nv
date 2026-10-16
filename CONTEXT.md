# Notational Velocity: terminology

Canonical vocabulary for the adopted immutable-segment design. This is a glossary: product rules live in the [specification](docs/iCloud-Drive-Support-Spec.md), algorithms in [Protocol](docs/impl-proposal-5/Protocol.md), and storage/field mappings in [proposal 5](docs/impl-proposal-5/README.md). Legacy-only terms are separated at the end.

## Concept hierarchy

Read from the thing the user owns toward its representations and effects. A collection has repository/local-store copies; its history contains operations grouped into actions and transported in objects; relationships between those records determine Current, conflicts and Undo/Redo. Files and provider observations are a separate representation/evidence layer, and physical authority governs operations on those copies.

- [1. Collections and their copies](#1-collections-and-their-copies)
- [2. History records and stored objects](#2-history-records-and-stored-objects)
- [3. History relationships and derived views](#3-history-relationships-and-derived-views)
- [4. Change processing and durability](#4-change-processing-and-durability)
- [5. Notes, deletion and conflict evidence](#5-notes-deletion-and-conflict-evidence)
- [6. Actions, undo and editing](#6-actions-undo-and-editing)
- [7. Note files and provider observations](#7-note-files-and-provider-observations)
- [8. Explicit conflict choices](#8-explicit-conflict-choices)
- [9. Authority, repair and transitions](#9-authority-repair-and-transitions)
- [10. Legacy-only vocabulary](#10-legacy-only-vocabulary)

Names listed under _Avoid_ are not forbidden English words: they are unsafe substitutes for that particular concept. Exact code identifiers and wire fields remain spelled as specified in their annexes.

## Language

### 1. Collections and their copies

Definition sources: [storage and ownership](docs/iCloud-Drive-Support-Spec.md#storage-identity-and-ownership), [proposal layout](docs/impl-proposal-5/README.md). For the bounded startup interpretation, see [SegmentBootstrapSafety](docs/tla/SegmentBootstrapSafety.tla).

**Collection**:
The logical set of notes and their retained NV history, independent of the folder or Mac holding a copy.
_Avoid_: Folder identity, one database file

**Segment collection**:
An NV collection whose retained immutable operation history supplies recovery and synchronization, with an explicit plaintext-file or encrypted-segment profile.

**Collection identity**:
The identity of one collection's bootstrap and history, shared by its legitimate copies. It does not identify or authorize access to a particular physical folder.
_Avoid_: Root identity, device identity

**Collection profile**:
The collection-wide choice of plaintext-file or encrypted-segment representation and its required content rules.
_Avoid_: Provider brand, a remotely synchronized preference

**PlaintextFilesV1**:
The collection profile with interoperable plaintext note files and visible retained NV history.

**EncryptedSegmentsV1**:
The collection profile with authenticated encrypted provider history and no plaintext note projection in that provider folder.

**Repository**:
The user-selected collection folder and its contents: required NV Data history plus separate note files when the collection profile provides them. A repository is a physical copy of a collection, not all private application state.
_Avoid_: NV Data alone, Application Support

**NV Data**:
The visible repository subdirectory holding required portable history and collection/key descriptors.
_Avoid_: Disposable sync metadata, the entire repository

**Local store**:
One private host copy of retained history and private state, including changes not yet published to the provider. “Private store” is the same concept.
_Avoid_: Expendable cache, repository

**Live note store**:
The complete current in-memory note collection and its pending admitted changes, authoritative during use.

**Local State**:
The local store's required settings, collection/root association, history-loss evidence, unfinished verification requests, local observations and pending-file references/operation reservations. These are logically separate from portable history and disposable acceleration, even when stored in the same private database.
_Avoid_: Synced preferences, startup cache

Verified private repair/copy retains older pending-input capture scopes as provenance
while assigning independent private ownership. Those retained scopes make the exact
saved inputs readable; new physical effects still require the destination's fresh
root/file checks. Repeated repair carries these existing bindings from every
contributing private source and requires exact agreement on repeated identities.
See [private record layout](docs/impl-proposal-5/plan/private-record-contract.md#encodings)
and [private copy preparation](docs/impl-proposal-5/plan/phase5/06-repair-replacement-and-copy.md#fixed-copy-preparation-and-final-handoff).

**Verification request**:
A small host-private durable record identifying the exact accepted object, bootstrap or local accepted prefix whose checks remain unfinished. Commit it before inspecting that evidence and retain it through the final consistency check. Successful completion settles that exact request; discovered damage replaces it atomically with the required-history damage marker. Reopening repeats unresolved checks before editable publication. Its prefix belongs to its original private store. See [verification recovery](docs/impl-proposal-5/plan/phase-4-improvements/durable-verification-recovery.md).

**Current-state materialization**:
The private database's derived current-note rows and authoring context, maintained through an exact prefix of accepted history. It is not a second history archive or the live store's pending user input.

**Local acceptance batch**:
One atomic addition of validated, complete history to a local store, including its required bookkeeping. Its local sequence orders materialization catch-up, not causality, provider delivery or cross-machine identity.

**Blocked receive candidate**

Retained, unaccepted incoming bytes whose dependency chain includes an object with
a recorded rejection. The diagnostic identifies those prerequisites and reasons;
the candidate's own validation awaits usable prerequisites. Missing data,
unsupported prerequisite data and damage to already accepted history remain
distinct. See [local receive handling](docs/impl-proposal-5/LocalStore.md).

**Receive requirement**:
An exact object locator plus its required role: retained bytes for assembling a
snapshot, or accepted history for interpreting causal records. Immutable inputs
reconstruct these roles; the private reverse-wait index stores object IDs. A
usable page can satisfy a byte requirement before its containing snapshot is
accepted. See [snapshot intake](docs/impl-proposal-5/plan/phase4-received-snapshot-validation.md).

**Startup-required receive work**:
Ready Changes and their discovered prerequisites, selected independently of queue
order before healthy current-note publication. Bootstrap, reconstruction, known
history checks and unfinished verification obligations also remain required.
Independent optional snapshots stay durably queued until successful checked host
publication starts the existing receive worker. See [returning launch](docs/impl-proposal-5/LocalStore.md#concrete-returning-launch-algorithm)
and [scheduling coverage](docs/tla/OptionalReadyStartupSafety.tla).

**Local tail**:
Locally retained history not represented by the current materialization or a provider snapshot. It need not be unpublished or belong to only one writer.
_Avoid_: Only unsynced edits, highest sequence number

### 2. History records and stored objects

Definition sources: [protocol identities](docs/impl-proposal-5/Protocol.md#identities-and-the-causal-graph), [object envelopes and keys](docs/impl-proposal-5/Encryption.md), [repair/pin decision](docs/adr/0016-repair-from-validated-immutable-copies.md). [SegmentActionRecoverySafety](docs/tla/SegmentActionRecoverySafety.tla) couples action records to note values; it does not prove the byte format.

**Operation**:
One recorded logical change, such as creating a note, replacing its value, deleting its birth, or retiring a conflict identity. Operations carry causal relationships; they are not filesystem commands.
_Avoid_: Action group, file write

**Operation identity**:
The identity of a canonical change including its causal inputs, independent of its enclosing transport envelope.

**Action group**:
One meaningful user action and its member operations, described by one action record. Several complete action groups may share a segment, but a group is not split across segments in v1.
_Avoid_: One segment per action, serialized undo invocation

**Action record**:
The retained description of an action group's membership, before/after values, undo scope and compensation relationships.
_Avoid_: Another stream of note mutations, executable command

**Immutable object**:
A complete retained unit of exact bytes whose identity does not change on copying or retransmission. Repository objects include segments and collection/key descriptors; not every object is a note revision.
_Avoid_: Note, mutable current file

**Object envelope**:
The encoded outer container that identifies and protects a payload's kind and collection/local scope. Provider segments use this container; private SQLite current/state rows have separate local protection and are not provider envelopes.
_Avoid_: Segment payload, every envelope is synced

**Compression profile**:
The byte-level rules for optional compression, separate from encryption and logical
history identity. New storage uses zstd; provider envelope tag `1` means exactly
one bounded, dictionary-free frame. Private current-row dictionaries have their
own local codec metadata. Zlib is legacy epoch-4 database/WAL compatibility only.
See the [exact acceptance rules](docs/impl-proposal-5/Encryption.md#compression-profile).
_Avoid_: SQLCipher page encryption, a shared stream across segments

**Private current-row dictionary**:
Immutable formatted zstd bytes used to decode private current cells, addressed by
their full SHA-256 digest. Rows from multiple generations may coexist; the reader
loads named dictionaries with a bounded per-job preparation working set.
Dictionaries and referencing rows install atomically. This is derived
materialization metadata, rebuilt with current rows from healthy retained history.
See the [physical codec](docs/impl-proposal-5/plan/private-current-row-codec.md).
_Avoid_: Collection identity, provider snapshot, required pending input

**Segment**:
An immutable history object containing either complete operation/action groups or a typed provider-snapshot root/page payload. A segment's transport identity is distinct from the identities of the operations inside it.
_Avoid_: Active journal, file patch, private startup cache

**Segment locator**:
A reference identifying the exact retained segment containing required evidence. It locates bytes; an operation identity identifies the logical change inside them.
_Avoid_: Mutable path, latest segment

**Writer epoch**:
A fresh namespace for allocating sealed objects during an editable session. It is separate from action-origin provenance, collection identity and device identity.
_Avoid_: Machine ID, action origin

**Collection bootstrap**:
The collection's founding identity, profile and initial-import commitment, anchored by genesis and a bootstrap descriptor. Bootstrapping means establishing that foundation on a local store, not choosing the newest remote history.
_Avoid_: Ordinary app launch, empty-directory inference

**Genesis**:
The founding operation recording the collection's profile and commitment to its initial note set. Initial import completion is separate evidence that the promised set has arrived intact.
_Avoid_: An editable empty fallback

**Bootstrap/key descriptor**:
An immutable record identifying the collection's bootstrap and, for encrypted collections, its wrapped-key unlocking information. It is not a note's merge or projection descriptor.
_Avoid_: Mutable key pointer, private association

**Bootstrap pin**:
The local association's commitment to a particular collection bootstrap, profile and key identity. It answers which collection this store belongs to, not how much history it has accepted.
_Avoid_: Retained-history pin, newest-history proof

**Retained-history pin**:
Private evidence naming the history and descriptors that this local store has already accepted and must still possess. It can expose loss of previously accepted local history, but cannot expose a branch this store never learned about.
_Avoid_: Undo cursor, upload receipt, all-devices watermark

**Provider snapshot**:
An immutable snapshot of note values and indexes at a stated operation frontier, available as retained provider objects. An initial root names a flat page list; a general root names a paged manifest tree. Its represented logical operation ancestry is distinct from the objects required to verify it: a required envelope can also carry a complete action outside that ancestry. Reconstruction includes every locally accepted outside-cut operation, even one received before the snapshot root. The snapshot root is distinct from the filesystem root.
_Avoid_: Startup cache, latest database, canonical checkpoint

**Snapshot retention parent**:
An exact accepted snapshot-root locator recorded in a general v1 snapshot's paged manifest. The new root requires and covers that parent's previously validated object closure, allowing the private retained frontier to advance while every ancestor's bytes remain stored. It is distinct from an operation causal parent: covering a snapshot preserves its objects independently of which note revisions the new snapshot represents. The single format has eight category counts, with zero in the retention-parent count when no parents are named. See the [format contract](docs/impl-proposal-5/plan/general-snapshot-record-contract.md).
_Avoid_: Newest-state election, permission to prune snapshots, snapshot supersession

**Encryption recovery key**:
Secret key material supplied by the user to unlock an encrypted collection through its validated bootstrap. It is unrelated to a deterministic conflict recovery key.
_Avoid_: Conflict-copy identity, password hint

**Password-free collection**:
A collection with no secret required to recover its stored notes; it makes no at-rest confidentiality promise. Remembered password unlocking of an encrypted collection is a different mode.
_Avoid_: Keychain-only encryption, remembered encrypted collection

**Envelope scope**:
The distinction between provider-shareable and host-private encoded objects, with private objects bound to their local store. This cryptographic/storage scope is not an Undo scope.
_Avoid_: Action scope, resolver scope

### 3. History relationships and derived views

Definition sources: [causal values](docs/iCloud-Drive-Support-Spec.md#causal-values-conflicts-and-deletion), [protocol graph distinctions](docs/impl-proposal-5/Protocol.md#identities-and-the-causal-graph), [SegmentMergeSafety](docs/tla/SegmentMergeSafety.tla). Model variable names have [specific abstraction boundaries](docs/tla/README.md#reading-model-names-against-the-specification).

**Causal parents**:
An operation's direct references to the operations it was based on or observed. Following these references backward gives its causal ancestry, which can include unresolved note alternatives.
_Avoid_: All revisions this operation replaces

**Note predecessors**:
The note revisions that a new value explicitly replaces. These describe note supersession, not everything its author knows.
_Avoid_: All causal parents, all known heads

**Scope parents**:
The maximal action records represented by a new action's captured undo-scope history. These order actions for Undo/Redo; they are neither note predecessors nor compensation targets.
_Avoid_: Arrival-ordered stack, operation-parent list

**Accepted history**:
Validated, dependency-complete history adopted and durably retained by the local store. Merely receiving an object does not make its contents accepted history.
_Avoid_: Every downloaded object, applied live state

**Accepted frontier**:
The maximal operation identities in accepted dependency-closed history. Qualify it as accepted, applied or represented when the distinction matters.
_Avoid_: Largest sequence, all-devices watermark

**Applied frontier**:
The maximal operation identities in the history already incorporated into the live model, including its known alternatives. It excludes received-but-unapplied history; locally admitted pending changes can already be applied, and known alternatives need not be represented by Current.
_Avoid_: All received objects, Current's note heads

**Represented frontier**:
The operation frontier whose history a particular snapshot, materialization or prepared result represents. A segment frontier instead names segment locators, and an action frontier names action IDs; these are different reference sets.
_Avoid_: Unqualified frontier, globally latest state

**Dependency closure**:
All exact ancestors and referenced evidence needed to validate and interpret specified NV history. “Complete closure” is complete relative to those inputs, not proof of everything on other Macs.
_Avoid_: Whatever files arrived, global completeness

**Reduction**:
Computing the current notes, conflicts and derived indexes from validated retained operations. The reducer interprets history; it does not create a new user action merely by displaying a result.
_Avoid_: Replay of executable remote commands, new save

**Derived state**:
A value or index reconstructible from retained evidence, such as a merge result or undo-candidate index. Derived does not mean unimportant, but means it is not the only copy of the underlying evidence.
_Avoid_: New independent user operation

### 4. Change processing and durability

Definition sources: [local admission and recovery](docs/iCloud-Drive-Support-Spec.md#local-admission-sealing-and-recovery), [protocol persistence boundary](docs/impl-proposal-5/Protocol.md#admission-sealing-and-durability-without-a-second-wal), [ImmutableSegmentDurabilitySafety](docs/tla/ImmutableSegmentDurabilitySafety.tla) and [SegmentDeletionSafety](docs/tla/SegmentDeletionSafety.tla). Their installation/acceptance abstractions differ; see the model-name guide linked above.

**Admitted change**:
A mutation accepted into the live note store and pending work. It is visible immediately but may not yet be locally durable.
_Avoid_: Accepted history, saved, acknowledged

**Captured change**:
A frozen value and its exact action/causal inputs prepared for asynchronous persistence or another guarded operation. Later edits are different generations, not modifications to the capture.
_Avoid_: Disk write, fresh permission forever

**Sealed object**:
An object whose final encoded and integrity-protected bytes have been fixed for installation and retry. Sealed bytes can still exist only in memory.
_Avoid_: Locally durable, uploaded

**Locally durable history**:
Complete validated final objects and their dependencies retained across the claimed local crash boundary.

**Local durability barrier**:
The complete local persistence boundary required before NV acknowledges a change as crash-durable. A completed file write or final-name installation alone is not that entire boundary.
_Avoid_: Upload completion, save callback

**Durability acknowledgment**:
NV's confirmation that a specific captured change and its required local history have crossed the local durability barrier.
_Avoid_: Provider receipt, mere admission

**Parked object**:
A received object retained while required dependencies, keys or supported decoding remain unavailable. Parking is not live application or an empty change.
_Avoid_: Rejected history, applied state

**Provider publication**:
Making an exact locally durable history object available in the selected provider repository. It is separate from publishing a prepared change into the live model.
_Avoid_: Atomic model publication, proof of peer receipt

**Immutable installation evidence**:
An operation/session-bound result proving exact checked bytes were installed or verified at their canonical repository name with the required file and affected-directory barriers. Equal-file retry performs the same verification and durability work. The publisher separately requires private accepted-history evidence. See the [physical boundary](docs/impl-proposal-5/plan/phase5/02-immutable-files-validation.md).
_Avoid_: Local history acceptance, cloud upload acknowledgment

**Reconciliation transaction**:
The preparation and validation of a proposed live-model change from captured history or file observations, ending in atomic model publication when still applicable.
_Avoid_: Cross-file transaction, cloud commit

**Atomic model publication**:
Making a validated reconciliation result and its dependent live indexes visible together, or making none of them visible. It describes one local live-model transition, not atomic files or a simultaneous cross-Mac commit.
_Avoid_: Provider publication, cross-file transaction

### 5. Notes, deletion and conflict evidence

Definition sources: [causal deletion and preservation](docs/iCloud-Drive-Support-Spec.md#causal-values-conflicts-and-deletion), [reduction and conflict identities](docs/impl-proposal-5/Protocol.md#note-reduction-concurrent-edits-and-intentional-deletion), [SegmentDeletionSafety](docs/tla/SegmentDeletionSafety.tla) and [SegmentMergeSafety](docs/tla/SegmentMergeSafety.tla). Recently Deleted list membership has separate [integration requirements](docs/impl-proposal-5/Verification.md#required-history-feature-integration-matrix), not a complete model proof.

**Note birth**:
The logical identity of one creation; restoration after deletion is a different birth.

**Note revision**:
One retained note-value operation in a birth's history. Revisions can coexist as alternatives rather than forming one timestamp-ordered list.
_Avoid_: Physical file version, latest timestamp

**Note head**:
A note revision not superseded by another applicable revision in the evaluated history. Several heads may exist for one birth.
_Avoid_: Newest timestamp, filesystem HEAD

**Represented revisions**:
The exact revisions embodied by a note's Current value: one revision, an equal-value set, or the inputs of a validated derived merge. Knowing another alternative does not mean Current represents it.
_Avoid_: All known revisions

**Current**:
The note value shown for ordinary editing, representing a particular revision or identified derived state. Capitalized Current is not the provider's current file version.
While local editing temporarily pins its own head, keep that displayed value paired with its actual represented revisions. This presentation pin is not the retained-history durability pin. Once releasable, schedule generation-fenced reduction even without another provider event; identical causal frontiers alone do not prove that two captured Current values or represented-input sets match. See [note reduction](docs/impl-proposal-5/Protocol.md#note-reduction-concurrent-edits-and-intentional-deletion) and [CompensationOverlapBridge](docs/tla/CompensationOverlapBridge.tla).
_Avoid_: All known heads, provider-current

**Logical Delete**:
An explicit causal command making its target birth absent, distinct from disappearance of a plaintext file.

**External-deletion candidate**:
A verified current-file disappearance with no applicable logical Delete, awaiting the configured confirmation decision.

**Conflict note**:
An ordinary separately identified note preserving a differing or explicitly recovered value.

**Preservation**:
Retention of differing source evidence, and where required an ordinary conflict note, without permission to destroy or overwrite unrelated work.

**Automatic preservation**:
A derived conflict note representing still-uncovered concurrent work. Unlike an explicit copy or independent user edit, its untouched presence can cease to be needed when more deletion evidence arrives.
_Avoid_: Automatically committed recovery

**Retired deterministic conflict identity**:
An explicitly retired conflict-copy/preservation birth whose deterministic recreation is suppressed by retained history.

**Conflict recovery key**:
A deterministic identity for the selected conflict-copy content from a particular source note. It is not an encryption secret; mutable title, labels and filename do not define this key.
_Avoid_: Encryption recovery key, provider-version ledger

**Recovery slot**:
One candidate conflict-copy identity associated with a conflict recovery key and an ordinal. Distinct slots allow safe handling of an occupied or previously retired candidate.
_Avoid_: Filename collision suffix, Apple version ID

**Derived merge**:
A deterministic current view computed from exact retained heads and a base, not a new user operation.

**Merge descriptor**:
The identity and provenance of a derived merge's algorithm, exact inputs/base and result.

**Restoration**:
An explicit fresh-birth creation referring to a previously deleted birth or historical value.

**Note History**:
The inspectable retained NV revisions, actions and merge provenance known for a note, not all Apple versions.

**Recently Deleted**:
The view of applicable logical deletions and recoverable prior values, excluding source entries already explicitly restored by durable restoration evidence. Deleting a restored fresh birth creates its own entry, not revival of the original one.
_Avoid_: Filesystem Trash, permanent erase

### 6. Actions, undo and editing

Definition sources: [history and undo policy](docs/iCloud-Drive-Support-Spec.md#note-history-recently-deleted-and-undo), [action-record rules](docs/impl-proposal-5/Protocol.md#action-records-and-cross-launch-undo), [CausalUndoRules](docs/tla/CausalUndoRules.tla) and [ConcurrentUndoExecutionSafety](docs/tla/ConcurrentUndoExecutionSafety.tla). Native spans and attached views have separate bounded checks in [NativeUndoSpanSafety](docs/tla/NativeUndoSpanSafety.tla) and [SharedNoteViewOwnershipSafety](docs/tla/SharedNoteViewOwnershipSafety.tla); none reconstructs AppKit's executable undo objects from history.

**Action origin**:
Recorded provenance grouping the actions authored in one editable collection session. It is retained with action history but is not a private continuation owner or an authenticated person/device.
_Avoid_: Undo owner, writer epoch, machine ID

**Undo scope**:
The note or collection context in which an action participates in Undo/Redo candidate selection. It is not the set of note revisions a resolver may dispose or the encryption envelope's local scope.
_Avoid_: Global stack, envelope scope

**Action frontier**:
The maximal represented actions within one undo scope. The authoring frontier used to record new scope parents is distinct from a lazily loaded history-view index.
_Avoid_: Operation frontier, displayed history rows

**Undo/redo candidate**:
An action eligible for consideration by the requested command, subject to current-value and admission checks. A candidate needing review is not silently skipped in favor of an older easier action.
_Avoid_: Automatically executable command

**Portable causal undo**:
Repository-derived Undo/Redo eligibility across all validated action origins in one note or collection scope. A unique causally maximal applicable candidate may proceed; incomparable or overlapping candidates require explicit review rather than arrival-time ordering.

**Compensation**:
A new action reversing an applicable earlier effect against current values without rewriting that earlier history. Compensation targets identify the actual action being reversed, independently of causal ordering; Undo after Redo targets that actual Redo.

**Compensation target**:
The actual action reversed by an Undo/Redo action. A target link says what was reversed; scope-parent links say what was observed.
_Avoid_: Original forward action in every redo cycle

**Compensation family**:
An independent whole action and its descendants through compensation-target links; scope-parent observation alone does not join families. Partial-native coverage can relate a command to several saved-action families.
_Avoid_: Scope-wide conflict flag, globally consumed undo branch

**Command-relative ambiguity**:
Uncertainty involving the requested Undo/Redo candidates, their compensation families or affected current values. An unrelated historical fork is not a permanent conflict flag on the entire note.
_Avoid_: Scope-wide conflict flag

**Reviewed compensation**:
An explicitly approved continuation of a captured Undo/Redo request that records the actual before/after reversal. It is not independent historical recovery or a provider-version disposition.
_Avoid_: New edit merely because a review view was used

**Undo/redo branch**:
The derived eligible causal sequence in one note or collection scope. An independent causal descendant supersedes redo eligibility in that scope even when that descendant is later undone/redone; compensation commands preserve the remaining eligible redo sequence. Concurrent arrivals preserve alternatives for review. Retained immutable history remains.

**Native typing undo**:
Fine-grained in-session AppKit undo associated with the current editable text state. Its executable objects, grouping and selections are neither serialized nor portable, though durable remaining effects are represented by action records.

**Remaining effect**:
The part of a saved action not yet reversed by fine-grained native undo. Remaining-effect coverage connects native undo to durable action history without claiming an entire action was reversed.
Ordered coverage uses the newest claim; incomparable maximal claims require review
and consume the group only when all are complete. Actual Current's represented
note lineage determines the applicable remaining state for its next reversal.
_Avoid_: Reconstructed keystroke stack

**Note view attachment**:
A window's generation-tagged presentation of a shared live note, not an owner of an independent note model, pending save or undo branch. Its query/layout/live selection is independent; the note's remembered cursor range takes the most recent update.

**Committed editing state**:
Text accepted through normal input handling and eligible for ordinary action capture. Here committed distinguishes completed input from composition, not acknowledged disk durability. The shared-view probe/model retains a separate snapshot as one candidate adapter; the [input contract](docs/iCloud-Drive-Support-Spec.md#input-and-content-scope) does not require that buffer or an NV-owned composition state machine.
_Avoid_: Every text-storage notification, locally durable

**Marked draft**:
AppKit-managed provisional input-method text that can be visible in the shared text storage. Its presence is not by itself a completed user action, synchronization conflict, or reason to prompt. NV must preserve standard input behavior; no separate durable draft format or universal rule about crash-snapshot contents is adopted.
_Avoid_: Saved edit, acknowledged history

### 7. Note files and provider observations

Definition sources: [separate-file policy](docs/iCloud-Drive-Support-Spec.md#separate-plaintext-files), [projection stamp and decision matrix](docs/impl-proposal-5/Protocol.md#projection-stamp-and-delayed-history-handling), [ProjectionStampSafety](docs/tla/ProjectionStampSafety.tla). Physical observations are constrained by the [Apple API evidence](docs/Apple-API-Contract-Validation.md), not inferred from logical history.

**Separate note file / projection**:
An interoperable current representation of a note that can accept external edits, distinct from retained NV history.

**Projection descriptor**:
A claim relating a note revision to intended path/format/exact bytes, not proof that any physical installation occurred.
The [P6.1 descriptor value](docs/impl-proposal-5/plan/phase6/02-projection-descriptor-contract.md)
retains the exact filename spelling, plaintext format and encoded-byte digest.
The [P6.1 history binding](docs/impl-proposal-5/plan/phase6/03-history-observation-contract.md)
adds complete source occurrences for private intended/accepted descriptions.
The [portable section](docs/impl-proposal-5/plan/phase6/08-portable-projection-contract.md)
retains these claims in Changes separately from note/action identity, with exact
accepted-history dependencies. The [complete query](docs/impl-proposal-5/plan/phase6/10-complete-binding-query-contract.md)
reads checked source history; the [local producer](docs/impl-proposal-5/plan/phase6/11-projection-producer-contract.md)
freezes an owned output into an exact-byte retry handle and accepts it through the
durable receive queue. Its receipt records portable history, while rooted receipt
issuance records actual file completion. Its captured Changes-frontier dependencies
retain earlier descriptions independently of the binding's note revisions;
atomic acceptance clears only those checked parents. `ProjectionLeafNameV1`
validates direct-child structure and reserved names, retaining exact byte equality
separately from case/normalization collision aliases. Filesystem applicability
remains a fresh rooted check.
`ProjectionFilenameV1` selects a leaf from captured extension settings, current
and other-note names, and directory occupancy using NV's title/suffix policy;
its [contract](docs/impl-proposal-5/plan/phase6/04-filename-preparation-contract.md)
keeps name preparation separate from current physical permission.

**Projection stamp**:
Advisory metadata carried with a separate note file that identifies its claimed NV source revision and exact projected bytes.
The bounded Swift `ProjectionStampV1` [record contract](docs/impl-proposal-5/plan/phase6/01-projection-record-contract.md)
also represents complete equal/merged source sets and automatic-preservation provenance.
Its `ProjectionBytesDigestV1` hashes exact encoded file bytes, while `NoteValueDigest`
identifies the semantic stored note value. History and current-file validation
establish whether a parsed stamp applies.
`CheckedProjectionHistory` is the Runtime's
[standalone source evidence](docs/impl-proposal-5/plan/phase6/07-inbound-history-contract.md):
exact accepted occurrences and reconstructed contents, bound to one current-view
capture. Its consumer rechecks that capture. File bytes, duplicate claimants and
physical association require their own checks.
`CheckedProjectionBindingHistory` supplies the same fenced contents for a
[complete descriptor](docs/impl-proposal-5/plan/phase6/10-complete-binding-query-contract.md),
including a represented set too large for the optional stamp. Reading a binding
from an accepted Changes object and validating its source remain distinct from
verifying a current physical file.

**Projection receipt**:
Private evidence of a particular locally verified note-file installation or association. Unlike a projection descriptor or stamp, it records a local observation and needs fresh validation before another physical operation.
`AcceptedProjectionV1` serializes that earlier description; it is a passive record.
`PreparedProjectionIntent` instead carries Runtime-issued history/current-view
evidence for recording an intended output. Neither type is a live rooted receipt.
Its [exact encoded output](docs/impl-proposal-5/plan/phase6/09-exact-output-contract.md)
uses retained UTF-8 history or private captured-byte chunks. The resolved encoding
and actual bytes stay together; another platform's encoder cannot regenerate
an earlier physical-byte observation merely from an encoding identifier.
_Avoid_: Portable deletion permission, upload receipt

**File observation**:
An exact locally rooted snapshot whose applicability depends on fresh identity/revision checks.
`ProjectionFileSnapshot` is the [P6.2 rooted reader's](docs/impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md)
immutable result: exact body, raw attribute presence, permissions and integer
filesystem times, checked through the same held descriptor and final name.
Its file-private issuer and contextual consumer checks bind it to that read.
Subsequent physical effects require their own operation-specific authority and
fresh verification.
File dates describe the filesystem's qualified representation of the requested
logical dates: HFS+/HFSX retains whole seconds and APFS retains nanoseconds.
Exact stage/install checks use that representation; retained note history keeps
the original dates. Coarse timestamps are not a substitute for body/metadata
verification.

**Filesystem identity evidence**:
Optional locally scoped association evidence, not a note birth or a guaranteed provider-stable identifier.

**Original local Delete permission**:
Live, operation-specific evidence joining a checked pre-Delete accepted source,
the root's coherent observation of that exact physical file, and the committing
owner's receipt for the same captured command. Its [P6.2 issuer and consumers](docs/impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#original-local-delete-permission--internal-implementation)
check the original session, connection and association. Persisted history and
recovery locations retain contents but cannot reconstruct this permission after
restart. The remaining durable source reservation and physical-move consumers
are separate integration gates.

**Accepted-file scan hint**:
Rebuildable private correspondence between a protocol path, a previously checked file fingerprint and an exact accepted immutable-object ID. Fresh rooted observation plus accepted membership permits skipping an unchanged body read, including across ordinary reopen. Session permissions separately govern the consumer; the hint grants no physical or completeness authority. See [discovery](docs/impl-proposal-5/Protocol.md#immutable-provider-publication-and-reception).

**Discovery metadata batch**:
Copied per-leaf observations or child failures from one bounded operation on a
held protocol directory. Ancestor checks bracket the operation. Pending raw
names receive fresh metadata after a returned turn; EOF keeps its stream alive
until the pending tail is consumed. This is an observation interval rather than
a complete or frozen provider catalog.

**Repository transport driver**:
The session-owned coordinator of bounded accepted-object publication and nested discovery. It coalesces hints and settlement notifications, retains an incomplete batch's exact bytes and cursor, and supplies an ordinary monotonic revisit after an empty pass. Paused errors retain their classification until explicit foreground/refresh or positive revalidation. Its reservations and cursors are transient execution state.

**Coordination interval**:
The synchronous execution of Foundation's actual accessor with its supplied URL(s). Rooted effects and their final verification run within this interval; copied bytes and observations then pass to independent history/database processing.

**Owned prepared stage**:
A uniquely held open descriptor for an exact immutable output between its preparation and final installation grants. The descriptor prevents inode reuse and permits metadata-only provider changes between grants. Installation rechecks exact bytes, physical identity, link count, the named source and all final barriers. The lease is confined to the root executor.

**Accepted-hint lookup batch**:
Checked, ordered answers for at most 64 file observations in one live private
store. The issuer binds the requests, root generation and store incarnation;
the consumer rechecks applicability. Each hit requires the existing fingerprint,
digest and exact accepted membership. Each miss uses ordinary exact receive;
durable effects remain per object. See [the batch contract](docs/impl-proposal-5/Protocol.md#bounded-metadata-and-accepted-hint-lookup).

**Provider catalog token**:
An equality witness for one coordinated shallow current namespace observation.

**Current-visible reconciliation**:
A fenced transaction over current plaintext-file observations, not enumeration of complete NV or Apple history.

**Repair-needed file relationship**:
A live note's missing or uncertain association under fresh reconciliation evidence. A known placeholder, temporary unreadability, an initial write still owed by NV, or a failed/incomplete root scan does not by itself mean the relationship is lost.

**Active projection comparison set**:
The captured note generation's concrete intended filename/format/bytes, plus the last accepted representation still being updated or moved by an unfinished save/rename/format transition. The prior representation leaves this set when the newer projection verifies and the transition settles; arbitrary history is excluded.

**Accepted projection / provisional relationship claim**:
The accepted projection is the last locally verified output/association receipt, including completed source accounting for a move. A provisional claim instead reserves a note's relationship during admitted repair; it fences competing choices but is neither installation proof nor deletion authority. Settling B can replace accepted A while intended C stays pending. Both serialized receipts and reconstructed transitions require fresh physical validation after restart.

**Plausible repair candidate**:
One live note needing relationship repair that independently matches the external file's active path or exact nonempty active projection bytes. This justifies an association question, not automatic identity assignment. Evidence is never pooled between notes.

**Frozen projection transition**:
The exact intended output and captured accepted source retained for one unfinished
per-note file transition. Newer intentions have their own slot. This private owner
preserves required bytes through restart until checked settlement transfers their
ownership. It is distinct from a pending external preview and from fresh physical
permission. See the [ownership contract](docs/impl-proposal-5/plan/phase6/13-frozen-output-contract.md).

A rename/update accounts for the captured original, reserved backup and new
output independently. With a case-only rename, the old spelling may also reach
the newly installed output on a case-insensitive filesystem. Source accounting
therefore checks physical observations and captured identities, rather than
equating an old spelling's presence with survival of the old file. The
[rooted relocation contract](docs/impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#native-renameupdate-candidate)
maps this to separate native source and installation results.

**Replacement/relocation attempt record**:
A private record of the frozen source/output, association and random backup
candidate selected before a same-name replacement or different-name rename/update. It lets recovery find
possibly displaced contents; fresh rooted checks establish what actually exists
and whether any later action is permitted. The
[P6.2 mapping](docs/impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#durable-replacement-candidate-reservation)
uses one existing per-birth slot for either operation. The source/output names
determine the operation; distinct live input/reservation/recovery types enforce
each consumer's role. The passive record remains distinct from an installation
receipt or completed settlement.

**Physical observation / metadata commitment**:
The rooted adapter's compact local description of a coherent file: nine physical
words plus a domain-separated SHA-256 commitment to its permissions, creation
time and raw encoding/tag/Finder/stamp attributes. Equality checks the captured
state even when coarse timestamps conceal a metadata change. Live root/session
and original-operation lifetime checks establish applicability. The complete raw
observation remains available for recovery; see the [P6.2 layout](docs/impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md).

**Live source descriptor lease (P6.2)**:
The descriptor transferred by an original local Delete or rename/update capture's coherent read.
One file-private resource owner shares it across immutable command/retry inputs
until their last release closes it. It pins the captured inode through quarantine;
the consumer still checks current bytes, metadata, root and operation ownership.
Root closure invalidates effect permission, and process restart retains only the
corresponding passive attempt record. See the [live capture contract](docs/impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#original-local-delete-permission--internal-implementation)
and [relocation mapping](docs/impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#native-renameupdate-candidate).

**Source-attempt record**:
A required-private recovery record committed before original-Delete protected capture.
It binds one random protected-directory key to the accepted source, Delete action,
root/association and complete original observation. Recovery issues fresh
read-only inspection inputs from this record; the live removal permission
expires with its original session. See the [P6.2 mapping](docs/impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#durable-original-source-reservation-and-inspection).

**Source quarantine (P6.2)**:
An exclusive move of a captured source to a reserved recovery filename, followed
by inspection of the actual moved file. A mismatching item is restored only to
an available source name; otherwise it stays retained for reconciliation. Its
physical result is separate from the original local Delete or move permission,
durable source accounting and eventual cleanup. See the
[candidate contract](docs/impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#native-source-quarantine--candidate-under-qualification).
This native preservation/public-relocation capability is separate from the
original-Delete Runtime path, which captures directly into protected storage.

**Owned source-artifact cleanup (P6.2)**:
The removal of an original live Delete's exact source while preserving a raced
replacement. One deletion accessor captures the public source directly into a
protected persistent directory derived from the attempt, compares its actual
contents and removes only the matching private child. Its receipt carries the
physical result and independent current observations; the required attempt and
private byte owners remain for later settlement. Restart supplies fresh
inspection. Genuine public renames retain move notifications, while temporary
preservation names stay implementation details so external editors keep their
correct save destination. The [Runtime consumer](docs/impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#active-presenter-correction-and-direct-removal-adapter)
uses one removal result instead of an intermediate capture plus cleanup. Its
receipt binds the original descriptor-lease identity. An attempt that created
an owned directory retains its record even when failure leaves it empty.
Ownership/privacy/crash qualification and later source accounting remain distinct.

**Pending-file item / latest pending snapshot**:

A private, nonblocking decision/recovery item and its latest successfully read and validated local file snapshot. New snapshots durably replace old preview inputs; disappearance/read failure does not erase the last readable input. It is not an archive of every external save, an Apple conflict, or committed note history.

**Operation reservation / frozen pending input**:
Private retry identity allocated before admission, and the exact snapshot an admitted operation must continue to use. A reservation is not consent or a committed command. Frozen inputs are independent of later preview updates; recover against actual durable operations before importing again.

A content-neutral association references existing represented history rather than inventing a note operation. A settled observation records that its Import/repair was handled; later editing/deleting the imported birth does not undo that fact. The [commit/recovery records](docs/impl-proposal-5/Protocol.md#pending-file-commit-and-recovery-records) define storage ownership and release, including old/new reference generations during an uncertain replacement.

**Consumed-input settlement / completed projection settlement**:
Two private record outcomes. The first retains an admitted input's exact decision
and host observation after releasing its preview. The second also records the
accepted output, relationship generation and completed source accounting. Only
fresh rooted checks permit publishing a completed projection. Both decoded
records remain passive historical evidence; their subsequent-input link records
work outstanding at completion, while current pending owners retain actual bytes.
See the [record mapping](docs/impl-proposal-5/plan/phase6/14-settlement-record-contract.md).

These definitions implement [IMPORT-01](docs/iCloud-Drive-Support-Spec.md#separate-plaintext-files). The [decision, active-state and retention rules](docs/impl-proposal-5/Protocol.md#current-file-decision-matrix) define their precedence, local storage and scope. [ExternalImportPolicyLab](docs/tla/ExternalImportPolicyLab.tla) compares observable signals; [ExternalImportAdmissionLab](docs/tla/ExternalImportAdmissionLab.tla) checks late-history admission; [Verification](docs/impl-proposal-5/Verification.md#external-file-admission-and-pending-recovery--adopted-policy) distinguishes lifecycle checks from production integration.

**Structural generation**:
The live-store generation distinguishing structural changes independently of an individual note's content generation.

**Provider visibility witness**:
Observed current file/catalog evidence accounting for a wakeup, distinct from the callback itself.

**Provider-current**:
The file version a provider reports as current to this observer. It is neither NV's editable Current nor proof of globally newest history.
_Avoid_: All devices current

**Materialized file**:
A provider file whose required content bytes are available locally for reading. An entry or placeholder can be visible without its body being materialized.
_Avoid_: Uploaded, globally synchronized

**Disclosed evidence**:
A particular object, file or version the provider has made known to this observer. An undisclosed branch cannot be inferred absent just because the local listing is quiet.
_Avoid_: Globally complete inventory

**Upload status**:
Advisory provider progress, distinct from local durability, another NV's receipt and repository completeness.

### 8. Explicit conflict choices

Definition sources: [resolver and Apple disposition](docs/iCloud-Drive-Support-Spec.md#conflict-resolver-and-apple-disposition), [implementation UI states](docs/impl-proposal-5/Implementation.md#conflict-resolver-and-asynchronous-operations), [disposition ADR](docs/adr/0014-distinguish-logical-deletion-projections-and-conflict-disposition.md). The [coverage map](docs/tla/Proposal5-Coverage.md) distinguishes shared Apple-disposition checks from [NVConflictCopySafety](docs/tla/NVConflictCopySafety.tla)'s representation-only copy policy; the [verification plan](docs/impl-proposal-5/Verification.md#nv-conflict-copy-disposition--adopted-policy) lists remaining integration boundaries.

**Unresolved provider version**:
An Apple-disclosed unresolved member for a visible note file, usable only within explicit scoped disposition.

**Conflict resolver view**:
The user-invoked dismissible read-only editor replacement showing Current and separately identified NV-head/Apple conflicts.

**Use this version**:
An explicit captured body choice for the original birth, with source-specific scoped disposition and unchanged title/labels.

**Save as new note**:
An explicit conflict copy into an exact reusable/new deterministic slot, or a fresh ordinary birth when invoked from general Note History. For NV conflicts, completion acknowledges only the copied revision without choosing, superseding or deleting the original's contents.

**Disposition**:
An acknowledgment limited to explicitly identified conflict evidence. NV causal disposition and Apple-member disposition have different evidence and completion rules; neither means global resolution or erasure of retained history.
_Avoid_: Global resolution, history removal

**NV causal disposition**:
Retained evidence that an explicit choice or copy represented particular NV conflict revisions. It does not cover an unobserved descendant or implicitly delete the original birth.
_Avoid_: Apple resolved flag, automatic Delete

**Representation-only copy disposition**:
Completed evidence that one exact NV conflict revision was preserved separately, removing its unresolved-attention entry without changing source-head reduction or Current selection. It remains valid after later copy modification/deletion; an empty unresolved list does not mean an absent or blank original.
_Avoid_: Implicit Keep Current, source supersession

**Apple-member disposition**:
The explicit resolution of a selected Apple-disclosed unresolved file-version member after its required local note/file checks. It is not a portable NV history operation.
_Avoid_: Complete historical-version cleanup

**Disposition scope**:
The exact source heads or Apple members captured for one explicit conflict choice or copy. This is distinct from an Undo scope and does not grow automatically when new evidence arrives.
_Avoid_: All future versions, undo scope

### 9. Authority, repair and transitions

- **Integrated collection session:** `CollectionSession` joins complete private
  startup, the selected physical association, checked host publication and
  independently scheduled repository transport. Local admission and provider
  status are separate outcomes. Its attempt generation fences publication,
  captures and a named Work Offline choice through reassociation.
- **Named startup wait:** one positively disclosed canonical provider object has
  unread bytes absent from the complete private closure before first publication.
  Its bounded materialization demand shares the transport worker/timer; request
  acknowledgment is distinct from authenticated readable bytes. Releasing this
  wait preserves pending evidence and gives no physical-effect permission.
  While a provider accessor is held, the original disclosure can support local
  release only after fresh local-health and same-live-root/attempt checks;
  readability itself remains unknown until the accessor settles.
- **Association settlement:** reconcile the existing SQL association's exact
  value/generation after a binding write. A committed new value is adopted after
  old work actually returns; an unchanged value retains the source; unreadable
  outcome retains one transition owning both resources for readback retry.
- **Complete bootstrap preview:** an issuer-restricted `BootstrapReadOnlyPreview`
  validates all snapshot pages/counts/digests and displayed values. Editable
  construction separately requires durable import/history closure and normal
  reopening. See [P5.5](docs/impl-proposal-5/plan/phase5/05-startup-and-root-reassociation-validation.md)
  and [the startup model](docs/tla/CollectionStartupAssociationSafety.tla).

Definition sources: [damage/repair policy](docs/iCloud-Drive-Support-Spec.md#repository-and-private-store-damage-and-repair), [repair protocol](docs/impl-proposal-5/Protocol.md#repository-and-private-store-repair-protocol), [RepositoryRepairSafety](docs/tla/RepositoryRepairSafety.tla). That model assumes a finite required-object set; it does not establish globally complete provider discovery.

**Accepted-name check**:
A bounded background observation of canonical repository names selected from a
fixed private accepted-history prefix. Background transport caps the prefix at
complete batches already passed by its publication cursor, leaving new outgoing
objects to their owned publication attempts. Its cursor belongs to the issuing store
session; its result also belongs to the observed root permission. An unchanged
hint can skip a body read only for the exact expected identity. Missing names and
changed occupied bytes feed ordinary repair/preservation classification. This is
distinct from validating the complete private repair union or a globally complete
provider inventory. See the [P5.6 mapping](docs/impl-proposal-5/plan/phase5/06-repair-replacement-and-copy.md#detecting-loss-after-publication).
The collection operation reservation defers admission of optional checks to the
existing periodic worker. This scheduling preference grants no source-stability
evidence; an entered check's writes still participate in the final copy/switch fence.

**Root session**:
One period of positively established authority over a particular physical collection directory and the work bound to it. “Root” here is the selected directory, not genesis or a snapshot-root object.
_Avoid_: Global notes path, collection identity

**Physical authority**:
Positive evidence and ownership permitting an operation on a particular local filesystem resource. Logical collection identity and authenticated history do not by themselves grant that permission.
_Avoid_: Matching path, valid ciphertext

**Generation fence**:
A check that captured note, store, root or lifecycle generations still match before using asynchronous results. The relevant generation is local validity evidence, not a distributed clock.
_Avoid_: Timestamp, permanent permission

**Root continuity unavailable**:
The nonterminal absence of positive same-root evidence, not proof that the folder was deleted.

**Root access capability**:
The platform/filesystem support needed to acquire and coordinate access to a positively bound root. A capability failure preserves repository contents and healthy private editing under the root-unavailable policy. Fresh deep-HFS+ opening is an explicitly permitted limitation; ordinary opening and reads after an already-owned deep move have separate qualification. See [ADR-0006](docs/adr/0006-retain-positive-association-and-directory-ownership.md).

**Root-directory lock**:
Local cooperating-writer exclusion on the opened directory object, not its pathname or a remote provider lease.

**Checked connection context**:
The fixed private-store, descriptor, schema and bootstrap-readiness facts established for one successfully opened database connection. Its owner reuses these in-memory facts within physically checked synchronous turns. A failed ownership check blocks that operation; retry requires positive identity of the same held resources. A new opening checks the facts again. Mutable record contents and asynchronous generations keep their own consumer checks. See [the connection contract](docs/impl-proposal-5/plan/phase5/private-connection-reuse.md).

**Provider-managed root**:
A selected root with positive provider-management evidence, without a provider-brand-dependent storage policy.

**Unclassified authority**:
A root without positive provider classification, not a proven ordinary-local directory.

**Edit-admission gate**:
The shared decision whether a new mutation may enter the live store given independent local-health, startup/lock and lifecycle reasons.

**Local durability suspension**:
The temporary admission block caused by invalid local ownership/association/key or inability to make admitted history durable.

**Working offline**:
Use of complete positively associated local history without waiting for provider availability.

**Repair union**:
The exact independently validated immutable objects available across the selected repair sources. It combines intact evidence, not damaged byte fragments or whichever file appears newest.
An unavailable subtree/file is reported by source and path while other selected
sources may supply its required objects. Continued acquisition retains its root
permission checks; only a complete known accepted union permits reconstruction.
_Avoid_: Newest copy, merged damaged bytes

**Stop-and-Save-As (occupied repository damage)**:
Preserve an occupied damaged protocol entry in place, pause affected provider writes and offer a fresh destination for available repository evidence plus saved local history. Healthy private editing continues. Missing entries still receive automatic exclusive repair; private-store activation and ordinary note-saving replacement are separate contracts.

**Save Current Collection As**:
An explicit history-preserving repository copy to another location, distinct from export of only current note values.

**Selection activation boundary**:
The owned physical installation of the selected-store record after candidate
verification and expected-current checks. Cancellation observed before installation
leaves the record unchanged; an entered effect uses durability/readback settlement.
An uncertain attempt retains its selection resources until retry or explicit close.
Closing a candidate revokes its live activation evidence while preserving its files.
An integrated Save As handoff reserves its admission earlier and owns a bounded,
independently settled activation task through late caller cancellation.
See [private repair activation](docs/impl-proposal-5/LocalStore.md#sqlite-backup-salvage-and-replacement-activation).

**Repository copy**:
A copy of all available NV Data contents and associated note files, preserving their retained history without requiring private local state or unpublished work.

An active saved-work copy reserves canonical destination names for exact verified
local history. Damaged source occupants at those names remain in the source and
are reported; no separate archive directory is added. Source-inventory coverage
and verified-history completeness are independent results.
An installation failure leaves its captured name reserved and its byte requirement
unmet; it does not select the damaged source as replacement contents.

**Saved-history copy inventory**:
A checked inventory of canonical names and hashes
at one accepted prefix. Bounded rereads supply the exact payloads for copying and
destination verification; inventory metadata grows with history, payload buffers
do not accumulate across batches.

**Verified copy switch**:
The integrated transition from an unchanged active source to a normally reopened
independent private copy and checked destination root. The final source check and
connection retirement precede selection installation. Uncertain selection keeps
both candidates and source exclusion until readback/durability settlement or close.
Known history and required private inputs have full coverage; unavailable repository
extras are separately reported and remain preserved at the source.

**Current-notes export**:
An explicitly current-state-only output, including legacy-format export or fresh-collection conversion, distinct from a history-preserving repository copy.

**Credential cutover**:
The verified transition to independently provisioned credentials/association while the source remains recoverable.

### 10. Legacy-only vocabulary

Definition sources: [legacy compatibility](docs/impl-proposal-5/README.md), [retired-model boundaries](docs/tla/README.md). The modern durability/deletion models call their derived state `materialization`; it is not a legacy checkpoint. Interpret other model identifiers through the model-name guide.

**Legacy database checkpoint**:
The complete Notes & Settings archive used by legacy stores and explicit epoch-4 exports.

**Accepted checkpoint / checkpoint base identity**:
The exact predecessor evidence used by legacy checkpoint/WAL recovery, not segment ancestry.

**Checkpoint-scoped state**:
The old archive's serialized state, a retired-model concept rather than the ownership rule for segment settings/history.

**Legacy WAL / journal recovery evidence**:
An ordered old-format recovery artifact associated with its legacy store, not an active segment-collection log.

**Checkpoint-current note reconciliation**:
The retired proposal-4 shared-checkpoint mismatch merge, absent from segment synchronization.

**Checkpoint-current witness**:
Exact local predecessor evidence for legacy/export mutable-checkpoint replacement, not a portable Apple revision or modern sync authority.
