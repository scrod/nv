# Notational Velocity

Vocabulary for NV's note storage and reconciliation domain.

## Language

**Live note store**:
The complete in-memory collection of notes, settings, metadata, and tombstones that is authoritative while NV is running.
_Avoid_: Memory cache, local cache

**Database checkpoint**:
A complete durable representation of the live note store used for fast startup and recovery. The user-visible file is named `Notes & Settings`; its note records are not a routine cross-device synchronization input.
_Avoid_: Cache file, sync database

**Accepted database checkpoint**:
The canonical database checkpoint used as the live-store and journal-recovery base after required validation. Recovery checkpoint versions are never accepted database checkpoints.
_Avoid_: Winning database branch, newest database

**Checkpoint identity**:
A fresh, never-reused random `checkpointID` that identifies one installed database checkpoint.
_Avoid_: Checkpoint version, checkpoint revision

**Durability journal**:
The ordered record of changes made during one editable root-session lifetime since its startup checkpoint. One process may therefore use successive journals while recovering or switching roots. The user-visible filename begins with `Interim Note-Changes`.
_Avoid_: Cloud log, synchronization database

**Journal identity**:
A random, never-reused identifier for one durability-journal generation.
_Avoid_: Writer identity, machine identity

**Checkpoint base identity**:
The exact accepted database checkpoint from which a durability journal begins. It is the checkpoint identity, or for an unchanged epoch-4 checkpoint a tagged SHA-256 digest of the exact loaded bytes.
_Avoid_: Database ancestry, writer identity

**Covering checkpoint**:
The exactly installed database checkpoint whose frozen live store represents a named journal's valid durable work. A retained claim records only that checkpoint's equality-only identity; a mismatch with the accepted checkpoint requires conservative recovery and never implies older/newer ancestry.
_Avoid_: Checkpoint ancestor, newer checkpoint

**Active journal**:
An opened notes directory's durability journal that this Mac expects to own and recover after an interrupted NV session. A Mac may have active-journal records for multiple notes directories; append ownership is separate from journal recovery eligibility.
_Avoid_: Local journal, writer journal

**Retained journal**:
A closed durability journal that this Mac still owns for recovery and cleanup because its exactly covering local checkpoint has not yet obtained the applicable upload qualification. Its current-host retained claim records the rooted-directory bookmark and covering checkpoint identity; it is not appendable, unclaimed, or proof of cloud durability.
_Avoid_: Foreign journal, sealed journal, uploaded journal

**Retained claim**:
The synchronized `NVRetainedJournal.<journalID>` current-host preference that records same-host recovery and cleanup ownership, the rooted-directory bookmark, and the exact covering checkpoint identity. It grants neither append authority nor upload qualification.
_Avoid_: Upload receipt, shared journal owner

**Represented-journal set**:
The exact active and retained journal identities represented by the accepted live store in one root session. A checkpoint receipt freezes this set as its journal coverage; it is reconstructed from claims and completed recovery rather than persisted as shared history.
_Avoid_: Journal ledger, checkpoint ancestry

**Journal ownership transition**:
The ordered crash-safe change between active, retained, and absent ownership. `demoting` means the retained claim is synchronized before the active claim is removed. `deleting/pending-durability` means removal succeeded or is ambiguous while the claim remains; `deleting/durable` begins only after root-directory synchronization succeeds following the current absence validation, and only then may the claim be removed.
_Avoid_: Journal sealing, journal absorption

**Unclaimed journal**:
A durability journal that is neither active nor retained in this Mac's current-host registry for its notes directory. It may contain recoverable work, but in a shared folder it may still belong to NV on another Mac.
_Avoid_: Foreign journal, abandoned journal

**Journal recovery eligibility**:
The classification of a structurally valid journal against the accepted database checkpoint as exact-base replay, already-represented cleanup, or base-mismatch salvage. LSN ordering proves order only within one journal.
_Avoid_: Journal ownership, provider-version resolution eligibility

**Separate note file**:
An interoperable representation of one note synchronized with the live note store. Under the first-class provider-managed storage contract these are unencrypted plain-text files and are the routine cross-device representation of note changes, while the live note store remains authoritative during a session.
_Avoid_: Authoritative note, database branch

**Persistent version identifier**:
An opaque provider identity for one immutable file version within a current-known snapshot.
_Avoid_: Version timestamp, version number, arrival order

**Provider catalog token**:
NV's immutable exact catalog-equality witness for one coordinated catalog observation. Despite the historical name, it is not a provider-issued revision. It has no ordering or increment semantics and may be projected into independent note and NV-artifact catalogs before use by their respective transactions.
_Avoid_: Catalog revision, scan timestamp

**Authoritative candidate URL set**:
The URLs eligible for exact version discovery, partitioned by purpose. The authoritative note candidate set contains current coordinated note-file children, retained live-model and last-note-catalog identities, presenter-delivered note move/version URLs, and visible conflict-recovery note files. The separate NV-artifact candidate set contains the fixed checkpoint, journal and lock names plus hidden operation residue under its normative name shape. The partitions may reuse one enumeration and provider lane but have independent catalog projections, dirty generations, completion, and retry state; an artifact failure cannot block routine note reconciliation. Spotlight results are not members solely by virtue of appearing in a query.
_Avoid_: Metadata-query results, global cloud inventory

**Exact provider fence**:
Equality of both the provider catalog token and the exact set of persistent version identifiers across a reconciliation transaction.
_Avoid_: Current flag, catalog timestamp

**Reconciliation transaction**:
A fenced note candidate derived from one current-known or explicitly current-visible provider snapshot. A complete transaction may publish its candidate atomically; an incomplete transaction may preserve only additive conflict evidence. Explicit database **Recover Notes** uses the same exact provider-fence machinery but is a distinct recovery producer, not routine reconciliation.
_Avoid_: Rescan, refresh

**Provider-version representation**:
The durable account of a selected provider state as the candidate original, a conflict note, an intentional tombstone, or explicit decision ancestry. Observation or output equality alone is not representation.
_Avoid_: Processed version, observed version

**Preservation**:
Additive retention of an otherwise unselected nondeletion state as a conflict note, or retention of a deletion as an identity-bound intentional tombstone. Preservation does not by itself confer provider-version resolution eligibility.
_Avoid_: Acceptance, resolution

**Provider-version resolution eligibility**:
The transient status a provider version gains only from either a complete exact routine reconciliation transaction or a complete exact database **Recover Notes** run representing every selected version. Partial/canceled recovery, unclaimed-journal recovery, preservation, **Discard**, and current-visible fallback never add it. Automatic resolution additionally requires local durability of its separate-file or tombstone representation, inclusion in an exactly verified checkpoint's resolution coverage, and, under provider management, exact upload qualification of that checkpoint. Upload confirmation for each separate note file is not required because the uploaded complete checkpoint is the recovery backstop.
_Avoid_: Preservation, processed version, accepted version

**Intentional tombstone**:
A durable deletion bound to a stable note or deterministic recovery-note identity rather than to a filename or path.
_Avoid_: Deleted filename, missing file

**Root session**:
The fresh, never-reused authority incarnation of one opened notes directory. A verified same-directory move under unchanged provider authority retains it. A confirmed authority/account change fences the old incarnation, transfers local durability resources to a provisional successor, attaches successor observation, and atomically makes that successor active only after namespace and journal revalidation. The provisional interval may continue healthy WAL durability but publishes no provider-derived result and refines to stuttering in the reconciliation models. Confirmed namespace deletion or replacement cancels the old or provisional incarnation and makes any later opening a fresh session. Resource teardown may wait while **Save Current Collection As** constructs an unattached destination, but no work may publish through a canceled or provisional incarnation. Asynchronous work may affect the live store only while its captured incarnation is active.
_Avoid_: Global notes path, root generation number

**Confirmed root loss**:
Positive evidence that the opened root directory object has been removed from the filesystem namespace and that no identity-equivalent logical provider item remains there: a validated vnode-delete notification on confirmed ordinary-local storage, or that event plus an AV-08-validated reverse File Provider lookup returning exact-domain `NoSuchItem` for the captured item. A missing path, stale bookmark, unavailable provider, revoked volume, presenter deletion accommodation, provider eviction, failed identity lookup, missing domain, or any other provider error is inconclusive; NV does not attempt to count other processes' open descriptors.
_Avoid_: Missing notes path, last file descriptor

**Journal durability suspension**:
The transient durability reason that selects NV's shared edit-admission gate when NV cannot establish recoverable local durability through the active journal descriptor and namespace, including vnode deletion or revocation, deletion accommodation, or journal append/barrier-sync failure. Already admitted edits remain in the live store and pending journal outbox; editing resumes only after rooted identity is revalidated and those records become barrier-synchronized. Provider-authority uncertainty alone does not select this state while local journal durability remains available.
_Avoid_: Read-only mode, provider offline

**Edit-admission gate**:
The single authoritative main-thread mutation check. Independent lifecycle-quiescing and journal-durability-suspension reasons may select it; either blocks a mutation, and clearing one reason never clears the other. Sharing the check does not merge the owners or semantics of those reasons.
_Avoid_: WAL gate, termination gate

**Save Current Collection As**:
Exceptional one-way construction of a new, exclusively created notes directory from NV's frozen authoritative in-memory store after the active root becomes unusable. It neither adopts nor reconciles an existing directory and gives the destination no authority over the inaccessible source.
_Avoid_: Root replacement, cross-root reconciliation

**Structural generation**:
A live-store generation that changes when note-to-file structure or its storage contract changes, including note addition or removal, filename rename, or serialization/storage-format change. It fences detached reconciliation commits independently of note content generations. A verified move of the same open root under unchanged provider authority changes neither note-to-file structure nor this generation; an authority change is fenced by a replacement session, while confirmed root loss cancels the old session and any reopened or newly saved directory starts a fresh one.
_Avoid_: Scan timestamp

**Provider visibility witness**:
Exact catalog/version evidence that a provider change callback has become observable. A generic callback remains dirty until a later exact observation differs from its saved pre-callback projection; a version callback is witnessed when its persistent identifier is present in the exact version set.
_Avoid_: Callback arrival time, polling timeout

**Current-known reconciliation**:
A reconciliation transaction over every authoritative candidate URL and every version returned for it by the required provider APIs within one exact fenced snapshot. It proves consistency of disclosed evidence, not the absence of undisclosed remote work.
_Avoid_: Fully synchronized, globally current

**Current-visible fallback reconciliation**:
A session-scoped best-effort transaction selected only by the operation-scoped stable-unsupported result defined by `CAP-01`. It fences the coordinated current namespace and visible current-file snapshots, may settle that visible work, and may consume its operational dirty generation, but never claims current-known completeness, confers provider-version resolution eligibility, or resolves provider versions. The limitation is session-continuous, not persisted.
_Avoid_: Complete reconciliation, provider mode

**Bootstrap reconstruction**:
The exceptional reconstruction of a replacement live note store when no acceptable canonical checkpoint can produce startup state. It is a fenced recovery operation, not the ordinary authority relationship between the live store and separate files. Its accepted discovery scopes, storage-format selection, checkpoint installation, and limited-history presentation are governed by `START-01`, `CAP-01`, and `CKPT-01` in the normative specification.
_Avoid_: Normal startup, reverse synchronization

**Recovery checkpoint version**:
A noncanonical or conflicting `Notes & Settings` version preserved as evidence for explicit recovery, not consumed during routine note synchronization.
_Avoid_: Database branch, sync replica

**Conflict note**:
An ordinary note with a new identity that preserves one irreconcilable version of a note while leaving it searchable and editable.
_Avoid_: Hidden version, conflict record

**Provider-current**:
A local cloud item that the provider reports as the newest version known to this Mac. It does not prove that no unseen remote edit exists.
_Avoid_: Globally current, fully synchronized

**Provider-managed root**:
An opened notes directory for which positive ubiquitous-item or File Provider domain evidence shows that a provider manages the selected item or an existing ancestor reached by the bounded same-volume authority walk. This identifies a storage authority boundary, not the provider's vendor or product name.
_Avoid_: Confirmed iCloud root, provider-name classification

**Working offline**:
An explicit mode in which NV permits edits against an available local database checkpoint without first obtaining a provider-current checkpoint, accepting later reconciliation.
_Avoid_: Read-only mode

**Credential cutover**:
The copy-on-write controlled restart for a passphrase, encryption, or storage-format change. The accepted preferences and Keychain item remain usable while an isolated target preferences snapshot and any fresh add-only target Keychain item are prepared and verified; exact target-checkpoint installation is the commit point, and old-item cleanup occurs only afterward.
_Avoid_: Live passphrase mutation, Keychain/checkpoint transaction

**Upload confirmation**:
A matched result for the pending upload transaction whose returned `NSFileVersion` identifies the exact installed local checkpoint version and checkpoint identity, including that receipt's provider-version resolution and represented-journal coverage. On older systems, only conservative upload qualification is available; any ambiguity retains the recovery evidence.
_Avoid_: Upload flag, cloud durable
