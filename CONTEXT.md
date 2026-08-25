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
The ordered record of changes made during one NV process lifetime since its startup checkpoint. The user-visible filename begins with `Interim Note-Changes`.
_Avoid_: Cloud log, synchronization database

**Journal identity**:
A random, never-reused identifier for one durability-journal generation.
_Avoid_: Writer identity, machine identity

**Checkpoint base identity**:
The exact accepted database checkpoint from which a durability journal begins. It is the checkpoint identity, or for an unchanged epoch-4 checkpoint a tagged SHA-256 digest of the exact loaded bytes.
_Avoid_: Database ancestry, writer identity

**Active journal**:
An opened notes directory's durability journal that this Mac expects to own and recover after an interrupted NV session. A Mac may have active-journal records for multiple notes directories; append ownership is separate from journal recovery eligibility.
_Avoid_: Local journal, writer journal

**Unclaimed journal**:
A durability journal that is not the active journal recorded by this Mac for its notes directory. It may contain recoverable work, but in a shared folder it may still belong to NV on another Mac.
_Avoid_: Foreign journal, abandoned journal

**Journal recovery eligibility**:
The classification of a structurally valid journal against the accepted database checkpoint as exact-base replay, already-represented cleanup, or base-mismatch salvage. LSN ordering proves order only within one journal.
_Avoid_: Journal ownership, provider-version resolution eligibility

**Separate note file**:
An interoperable representation of one note synchronized with the live note store. In first-class iCloud mode these are unencrypted plain-text files and are the routine cross-device representation of note changes, while the live note store remains authoritative during a session.
_Avoid_: Authoritative note, database branch

**Persistent version identifier**:
An opaque provider identity for one immutable file version within a current-known snapshot.
_Avoid_: Version timestamp, version number, arrival order

**Provider catalog token**:
An opaque equality token for one provider catalog observation. It has no ordering or increment semantics.
_Avoid_: Catalog revision, scan timestamp

**Authoritative candidate URL set**:
The URLs eligible for exact version discovery in one transaction: current coordinated direct children, retained live-model and last-catalog identities, presenter-delivered move/version URLs, and fixed NV artifact names. Spotlight results are not members solely by virtue of appearing in a query.
_Avoid_: Metadata-query results, global cloud inventory

**Exact provider fence**:
Equality of both the provider catalog token and the exact set of persistent version identifiers across a reconciliation transaction.
_Avoid_: Current flag, catalog timestamp

**Reconciliation transaction**:
A fenced candidate derived from one current-known provider snapshot. A complete transaction may publish its candidate atomically; an incomplete transaction may preserve only additive conflict evidence.
_Avoid_: Rescan, refresh

**Provider-version representation**:
The durable account of a selected provider state as the candidate original, a conflict note, an intentional tombstone, or explicit decision ancestry. Observation or output equality alone is not representation.
_Avoid_: Processed version, observed version

**Preservation**:
Additive retention of an otherwise unselected state as a conflict note or intentional tombstone. Preservation does not by itself confer provider-version resolution eligibility.
_Avoid_: Acceptance, resolution

**Provider-version resolution eligibility**:
The status a provider version gains only when a complete exact reconciliation transaction represents every selected version. Resolution additionally requires the applicable separate-file, checkpoint, and upload durability.
_Avoid_: Preservation, processed version, accepted version

**Intentional tombstone**:
A durable deletion bound to a stable note or deterministic recovery-note identity rather than to a filename or path.
_Avoid_: Deleted filename, missing file

**Root session**:
The fresh, never-reused incarnation of one opened notes directory. Asynchronous work may affect the live store only while that same incarnation remains active.
_Avoid_: Global notes path, root generation number

**Structural generation**:
A live-store generation that changes when note-to-file structure changes, including note addition or removal, filename rename, serialization format change, or root replacement. It fences detached reconciliation commits independently of note content generations.
_Avoid_: Scan timestamp

**Provider visibility witness**:
Exact catalog/version evidence that a provider change callback has become observable. A generic callback remains dirty until a later exact observation differs from its saved pre-callback projection; a version callback is witnessed when its persistent identifier is present in the exact version set.
_Avoid_: Callback arrival time, polling timeout

**Current-known reconciliation**:
A reconciliation transaction over every authoritative candidate URL and every version returned for it by the required provider APIs within one exact fenced snapshot. It proves consistency of disclosed evidence, not the absence of undisclosed remote work.
_Avoid_: Fully synchronized, globally current

**Bootstrap reconstruction**:
The exceptional creation of a replacement live note store from separate note files when no database checkpoint can be trusted. It is a recovery operation, not the ordinary authority relationship between the live store and separate files.
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

**Working offline**:
An explicit mode in which NV permits edits against an available local database checkpoint without first obtaining a provider-current checkpoint, accepting later reconciliation.
_Avoid_: Read-only mode

**Upload confirmation**:
A matched result for the pending upload transaction whose returned `NSFileVersion` identifies the exact installed local checkpoint version and checkpoint identity, including applicable recovery-evidence coverage. On older systems, only conservative upload qualification is available; any ambiguity retains the recovery evidence.
_Avoid_: Upload flag, cloud durable
