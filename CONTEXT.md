# Notational Velocity

Vocabulary for NV's note storage and reconciliation domain.

## Language

**Live note store**
The complete in-memory collection of notes, settings, metadata, pending deletion records, and retired deterministic conflict identities that is authoritative while NV runs.
_Avoid_: Memory cache, local cache

**Database checkpoint**
The complete durable representation of the live note store used for fast startup and same-Mac recovery. The user-visible file is named `Notes & Settings`; its note records are not a routine cross-device synchronization input.
_Avoid_: Cache file, sync database

**Accepted database checkpoint**
The canonical checkpoint used as the live-store and WAL-recovery base after validation. Noncanonical provider versions are not accepted or recovered by NV.
_Avoid_: Winning database branch, newest database

**Checkpoint identity**
A fresh, never-reused random `checkpointID` identifying one installed database checkpoint. It has equality semantics only.
_Avoid_: Checkpoint revision, ancestry

**Checkpoint base identity**
The exact accepted checkpoint from which a local durability journal begins: its checkpoint identity, or a tagged SHA-256 digest of exact unchanged epoch-4 bytes.
_Avoid_: Database ancestry, writer identity

**Checkpoint-scoped state**
Every live-store value serialized into `Notes & Settings` whose change can require a new checkpoint, including note records, the compact retired-deterministic-identity set, `NotationPrefs`, selection/UI state, and database-level metadata. An ordinary completed deletion is represented by omission from the complete note set, not by a permanent tombstone. The root session tracks divergence from the accepted checkpoint independently of WAL/file obligations; “nothing checkpoint-scoped changed” means that exact dirty generation still equals its accepted-checkpoint baseline.
_Avoid_: Whatever the WAL happens to contain, checkpoint-only metadata

**Durability journal / WAL**
The ordered host-local record of changes during one editable root-session lifetime. Modern WALs live under the current user's Application Support directory, never in the notes directory or provider namespace. They protect same-Mac crash recovery and are not a synchronization representation.
_Avoid_: Cloud log, provider journal

**Journal identity**
A random, never-reused identifier for one local WAL generation.
_Avoid_: Writer identity, machine identity

**Local WAL recovery evidence**
A self-describing Application Support WAL whose header bookmark resolves to the selected root. Every matching WAL is mandatory startup evidence until its valid work is represented by an exactly verified checkpoint or conservatively recovered. There are no active/retained preference claims or remote journals.
_Avoid_: Shared journal, retained claim

**Journal recovery eligibility**
Classification of a structurally valid local WAL against the accepted checkpoint as exact-base replay, already-represented cleanup, or base-mismatch salvage. LSN ordering proves order only within one WAL.
_Avoid_: Provider-version resolution eligibility

**Separate note file**
An interoperable representation of one note synchronized with the live note store. Under the first-class provider-managed contract these are unencrypted plain-text files and the routine cross-device representation.
_Avoid_: Authoritative note, database branch

**Provider catalog token**
NV's immutable equality witness for one coordinated shallow catalog observation. It is not provider-issued, ordered, or monotonic.
_Avoid_: Catalog revision, scan timestamp

**Authoritative current note candidate set**
The current coordinated direct-child note files plus live-model/last-catalog identities and note URLs delivered by presenter move callbacks. Hidden NV artifacts and `Notes & Settings` are excluded. Spotlight results are never authoritative inputs.
_Avoid_: Cloud inventory, metadata-query results

**Current-visible reconciliation**
A transaction over a complete coordinated current namespace and the selected current-file snapshots. Equal before/after catalogs and unchanged root/model inputs permit publication. It makes no claim about undisclosed provider history.
_Avoid_: Current-known, fully synchronized

**Reconciliation transaction**
A detached current-visible candidate that may affect the live store only after its catalog, root-session, structural-generation, and note UUID/LSN fences still match.
_Avoid_: Rescan, refresh

**Checkpoint-current note reconciliation**
The no-write recovery path after `NVCheckpointInstallCurrentChanged`: NV compares the retained accepted checkpoint, the complete live note set, and the exact complete current `Notes & Settings`. A UUID present in the base and absent from a complete branch is that branch's deletion; no other absence is deletion evidence. NV publishes only reconciled note states, base-relative deletion outcomes, and the union of retired deterministic conflict identities. Preferences and database-scoped metadata from the competing checkpoint are ignored. Any retry uses that exact current checkpoint as its expected predecessor.
_Avoid_: Database merge, historical checkpoint recovery

**Checkpoint-current witness**
One host-local, root-session-scoped snapshot captured inside the same coordinated accessor: exact complete checkpoint bytes, the existing `NVFileObservation` fields, and the current local `NSFileVersion.persistentIdentifier` when Apple supplies one. The persistent identifier is supplemental rather than a generation counter; live tests on macOS 14 and 26 kept it equal across a same-bytes Foundation replacement while the filesystem observation changed. Expected-current comparison rechecks every captured component, and a changed component rejects the write. The witness is never persisted or compared across machines.
_Avoid_: Provider revision, portable version identity

**Preservation**
Additive retention of a differing visible state as an ordinary conflict note. A delete/edit race omits the deleted source UUID and preserves the edited state under a distinct note identity only when that edited state is an available local/current-file or complete-checkpoint input. Routine current-file preservation uses the existing ordinary-note creation rules and fresh random version-4 identities; it never consults deterministic recovery candidates or their retirement to suppress that state. Checkpoint-current reconciliation and base-mismatched WAL salvage instead use the automatic deterministic identity and its reuse/retirement policy. If provider deletion removes the current file and Apple discloses no unresolved edited version, the current-visible design has no state to preserve; this says nothing about provider data not exposed through those inputs. Preservation never authorizes modification of Apple version history.
_Avoid_: Resolution

**Unresolved provider version**
An `NSFileVersion` Apple reports as unresolved for a currently visible note file. It is manual conflict-disposition input only. NV does not infer that the returned set is complete or persist its identifiers. Only an explicit action in the conflict resolver view may mark a disclosed member resolved; NV never removes one from the version store.
_Avoid_: Complete history, recovery checkpoint

**Conflict resolver view**
The user-invoked, nonmodal read-only view swapped into the editor split-view subview in place of `LinkingEditor` when the user clicks a conflicted note's alert badge. Its **Conflicts** menu contains **Current** plus the unresolved versions Apple disclosed for the operation. Selecting a member previews its immutable file contents; selecting **Current** previews the authoritative live note body. Its close **×** always restores `LinkingEditor` and dismisses only the view: per-version operations may continue in the background, re-presenting automatically starts a fresh bounded pass for parked operations without duplicating running ones, and only a fresh empty unresolved query clears the badge. It has no explicit Retry action.
_Avoid_: Historical version browser, automatic recovery

**Use this version**
The explicit winner choice in the conflict resolver view. **Current** keeps the authoritative live body; another selection copies only its body into the current note through the ordinary mutation path. After the resulting current-note WAL and exact separate-file obligations settle and remain exact inside coordinated revalidation, every unresolved member in that operation snapshot may be marked resolved. The original note identity, filename, title, labels, and database metadata remain unchanged.
_Avoid_: Replace version file, restore checkpoint

**Recovery key and slot**
The stable idempotency identity for **Save as new note**: a fixed versioned namespace plus source note UUID and canonical recovered body. Mutable title, labels, format, filename, provider identifier, and collision suffix are excluded. Candidate note UUIDs add a deterministic nonnegative slot; exact live-body candidates are reusable, while modified candidates and UUIDs in the retired deterministic conflict identity set occupy their slot and are never overwritten or resurrected.
_Avoid_: Recovered filename identity, provider-version ledger

**Save as new note**
The per-member additive disposition in the conflict resolver view. A selected conflicting version becomes one ordinary collision-adjusted `Title (conflict)` note using the captured source title/labels and previewed body. Only after its exact body/generation is WAL-durable, its separate file is exactly installed, and source/member applicability is coordinately revalidated may that selected provider member be marked resolved. **Current** cannot be saved through this action.
_Avoid_: Recover all versions, automatic conflict copy

**Conflict note**
An ordinary note with a distinct identity preserving an alternate visible or explicitly recovered state while remaining searchable and editable.
_Avoid_: Hidden version, conflict record

**Pending deletion record**
The UUID/LSN `DeletedNoteObject` retained in the pending set and host-local WAL until covered by a verified complete checkpoint. Ordinarily it records an intentional logical deletion. For a reserved version-8 UUID it also carries an idempotent retirement assertion. Ordinary conflict-note deletion admits only that UUID; the exceptional checkpoint-current reconciliation reasserts the complete merged retired set because its checkpoint predecessors have been displaced. Its legacy `syncServicesMD` has no modern semantics. It never identifies or authorizes deletion of a plain-text file; only the original exact-snapshot deletion operation may remove the represented file.
_Avoid_: Permanent tombstone, deleted filename

**Retired deterministic conflict identity**
A UUID from the reserved RFC 9562 version-8 deterministic namespace that once identified an explicit recovery note or automatic conflict-preservation note and was later deleted. Retired identities are stored as a compact monotonic checkpoint set and prevent deterministic retry from overwriting or recreating deleted conflict notes. They never identify or authorize deletion of a separate file.
_Avoid_: General note tombstone, provider-version ledger

**Filesystem identity evidence**
Optional candidate-association evidence: a nonzero document ID qualified by an equal volume UUID, or a nonzero file ID limited to one active root session. Either must be unique on both sides. Generation count is revision metadata. Missing or changed identity after eviction, rematerialization, replacement, or restart is an ordinary fallback condition, never proof of a different note by itself.
_Avoid_: Note identity, provider-stable identifier

**Root session**
A fresh authority incarnation for one opened notes directory. A verified move of the same rooted directory, with the same positive provider identity when one is available, retains it. A positive authority change fences the old incarnation. Loss of positive continuity makes the session unavailable until positive evidence restores it or an explicit user action ends it. Asynchronous work may publish only while its captured incarnation remains active and available.
_Avoid_: Global notes path

**Root continuity unavailable**
The nonterminal state entered when NV cannot positively establish that the opened rooted directory remains reachable as the same object. Missing paths, vnode deletion/revoke, stale bookmarks, provider unavailability, and lookup errors never prove deletion. Positive same-root evidence may restore the session, and positive changed-authority evidence takes the provisional-successor path; otherwise only explicit **Save Current Collection As…**, **Re-open from Disk**, collection abandonment, or quit ends it.
_Avoid_: Confirmed root loss, missing notes path

**Root-directory lock**
The nonblocking exclusive advisory `flock` on the already-open directory descriptor retained by the root session. It excludes cooperating local writers of that same directory object from startup/WAL discovery through local close and observer teardown, including gap-free same-root authority/controller handoff. It is not a lock file, a WAL lock, root-identity evidence, or a cross-Mac lease; a different directory at the old pathname is a different lock resource.
_Avoid_: Provider lock, pathname lock, journal ownership claim

**Journal durability suspension**
The transient edit-blocking reason selected when the local Application Support WAL cannot append or barrier-sync, or its association with the active root cannot be validated. Provider/network uncertainty alone does not select it.
_Avoid_: Read-only mode, provider offline

**Edit-admission gate**
The single main-thread mutation check. Acceptance mutates the live model and inserts the note or pending deletion record in the existing pending set but performs no archive or I/O; its current UUID/LSN is captured at the later coalescing or forced-durability boundary. Deleting a reserved deterministic conflict UUID also inserts it into the retired set. Independent lifecycle-quiescing and local-WAL-durability reasons may select the gate; either blocks later mutation.
_Avoid_: WAL gate, termination gate

**Structural generation**
A live-store generation changed by note addition/removal, note-file rename, or serialization/storage-format change. It fences detached commits independently of note content LSNs.
_Avoid_: Scan timestamp

**Provider visibility witness**
Current catalog/file evidence that accounts for a provider callback. Callback arrival alone is only a wakeup and never a fence.
_Avoid_: Callback timestamp

**Provider-current**
A local cloud item the provider reports as the newest version known to this Mac. It does not prove no unseen remote edit exists.
_Avoid_: Globally current

**Provider-managed root**
An opened directory for which positive ubiquitous-item or File Provider domain evidence establishes provider management. This identifies an authority boundary, not a vendor.
_Avoid_: iCloud-branded root

**Unclassified root authority**
An opened directory for which NV has no positive provider-management evidence. Absence, delay, lookup failure, and negative results do not establish that the root is ordinary local; they authorize only the generic conservative filesystem path.
_Avoid_: Confirmed ordinary-local root, noncloud root

**Working offline**
An explicit mode permitting edits against a complete local checkpoint and every matching local WAL without first obtaining a provider-current checkpoint.
_Avoid_: Read-only mode

**Save Current Collection As**
Exceptional construction of a new, exclusively created notes directory from the frozen live store after the active root becomes unusable. An exactly verified destination checkpoint may cover and retire the old host-local WAL; no WAL is copied to the destination.
_Avoid_: Root replacement, WAL transplant

**Bootstrap reconstruction**
All-or-nothing reconstruction of a replacement live store from a stable current-visible separate-file snapshot when no acceptable canonical checkpoint can produce startup state.
_Avoid_: Historical recovery, reverse synchronization

**Credential cutover**
The copy-on-write controlled restart for a passphrase, encryption, or storage-format change. The accepted checkpoint/Keychain pair remains usable until the isolated target pair is verified.
_Avoid_: Live passphrase mutation

**Upload status**
Provider-reported progress used for presentation and the existing quit UI. It is not a WAL-cleanup, provider-version-removal, manual conflict-disposition, or local-durability precondition.
_Avoid_: Cloud durability proof
