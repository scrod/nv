# Implementation proposal 5: immutable segment storage and provider sync

Status: active implementation plan for the adopted immutable-segment design. The [specification](../iCloud-Drive-Support-Spec.md), [ADRs](../adr) and [vocabulary](../../CONTEXT.md) now describe this design; proposal 4 is retired implementation reference. Production work and release gates remain incomplete. The [proof-priority/disposition map](../tla/Proposal5-Coverage.md) states exactly what the bounded models cover; adoption does not promote old checkpoint proofs or planned integration tests into segment evidence.

This proposal incorporates the simplification that **durable host-local segments replace the separate mutable WAL**. A segment's exact bytes are retained immutably in the private Application Support database and subsequently published to any user-selected provider folder. A locally verified segment supplies crash recovery. A provider copy supplies transport. Neither requires the other to finish.

## Reading order

| Document | Contents |
| --- | --- |
| This README | Scope, decisions, storage layout, authority, compatibility, adoption map |
| [Swift storage conformance and failure-testing strategy](plan/swift-storage-conformance-testing-strategy.md) | Defines every TC-* contract ID cited by the implementation plan and the strategies for testing them |
| [Protocol](Protocol.md) | Segment/action identities, conservative automatic merging, recovery and compensating undo, deletion, separate-file association, publication, snapshots, restart |
| [Local store and fast startup](LocalStore.md) | Private SQLite ownership/transactions, password-free/keyed recovery, backup/salvage/activation, required state versus derived current rows, indexed fast startup |
| [Encryption](Encryption.md) | Wire envelopes, keys, passphrases, bootstrap, trust boundaries, rotation, plaintext exposure |
| [Format TODO](Format-TODO.md) | Remaining byte layouts, canonical encodings, validation limits, dependencies and golden vectors for implementation phase 1 |
| [Implementation](Implementation.md) | Production-code changes, queue ownership, history/Recently Deleted/undo UI, editor and resolver behavior, failures, startup/close/migration, ordered work packages |
| [Window UI architecture](Window-UI-Architecture.md) | New Window and separate Recently Deleted viewer, shared collection/per-note ownership versus independent presentation, source extraction points and open UX details |
| [Verification](Verification.md) | Executed TLA+ results, required invariants, concrete integration cases, Apple API probes, remaining coverage and release gates |
| [Native undo experiments](Native-Undo-Experiments.md) | AppKit/span/undo-review evidence and the shared-note window, composition and lifecycle probes; candidate bridges versus remaining integration gates |
| [Swift implementation and testing plan](plan/swift-storage-implementation-plan.md) | Phased portable-library delivery using direct Swift canonical definitions (no CUE/generator), production-path conformance tests and qualification gates; reconciles the two input proposals with current policy |
| [Phase 5 multipart implementation plan](plan/phase5-provider-root-implementation-plan.md) | Dependency-ordered root/filesystem/transport/Apple/startup/repair increments, each tied to production tests, language boundaries and exit gates |
| [Phase 5 provider/root testing plan](plan/phase5-provider-root-testing-plan.md) | Actual disk/API qualification, rooted ownership, exact transport, connected crash/race schedules, independent observations and compiler/mutation gates |
| [Phase 6 plaintext implementation and testing plan](plan/phase6-plaintext-reconciliation-plan.md) | Dependency-ordered mutable-file operations, coherent classification, projection transitions, pending import/association, external deletion and connected recovery; language boundaries and qualification reuse |
| [P6.1 history/private-observation evidence](plan/phase6/03-history-observation-validation.md) | Checked current-history binding, durable intended output, preservation of accepted descriptions and complementary repair; physical receipt gates remain open |
| [P6.1 portable projection placement](plan/phase6/08-portable-projection-contract.md) | Optional Changes section, complete source/dependency checks and metadata-only acceptance; the subsequent producer/retention reports qualify local admission and exact-byte retry |
| [P6.1 exact encoded output](plan/phase6/09-exact-output-contract.md) | Requested-encoding/UTF-8 promotion, private captured bytes and atomic intent retention |
| [P6.1 frozen output ownership](plan/phase6/13-frozen-output-contract.md) | Independent unfinished-transition inputs, note-scoped chunks and atomic superseded-byte release |
| [P6.1 settlement qualification](plan/phase6/14-settlement-record-validation.md) | Complete consumed decisions, passive projection-owner transfer and final Intel process checks close P6.1; physical receipt publication remains P6.4 |
| [P6.1 complete-binding queries](plan/phase6/10-complete-binding-query-contract.md) | Exact accepted descriptions, full-source evidence and private-owned whole-output recovery, including oversized stamp omission |
| [P5.5 startup/reassociation evidence](plan/phase5/05-startup-and-root-reassociation-validation.md) | Integrated local admission, named provider waits, selected bootstrap, durable Retry/Re-open and current qualification boundaries |
| [First save/reopen contract](plan/first-save-reopen-contract.md) | Initial byte layouts, complete bootstrap and runtime ownership/API contract; status of the ordinary local storage subset versus remaining work |
| [Phase 2 Runtime evidence](plan/phase2-local-runtime-validation.md) | Implemented SQLCipher save/reopen path, frozen private codecs, process/fault/compiler/mutation checks and qualification boundaries |

Use [CONTEXT.md](../../CONTEXT.md) for canonical vocabulary. Protocol and Encryption are the normative algorithm/wire annexes referenced by the specification; fields explicitly awaiting byte vectors or review cannot be written as a production format yet. Retired checkpoint/WAL terms are legacy-only, not alternate definitions of segment authority.

For a first reading, start with Protocol's [terminology guide](Protocol.md#reading-the-terminology): logical collection → operation/action history → immutable storage → derived notes → physical files. It explains the different graph relationships and overloaded terms before introducing their fields. Use the [model-name guide](../tla/README.md#reading-model-names-against-the-specification) when following those concepts into TLA+: identical variable names do not imply identical abstraction boundaries.

## Product contract

Keep the authoritative live in-memory note store, immediate synchronous search, keyboard interaction, existing note formats in legacy/local collections, and interoperable separate text files. Provider calls, directory opens, encryption, parsing, and disk barriers never execute on the main thread. There is no dedicated iCloud container, CloudKit dependency, provider-brand switch, or custom File Provider extension.

There are two new segment-collection profiles:

| Profile | Selected provider folder | Local representation | Confidentiality |
| --- | --- | --- | --- |
| `PlaintextFilesV1` | Ordinary plaintext note files plus visible `NV Data/v1` immutable protocol files | Live store, durable segments, derived current rows, private local state | Plaintext interoperability; the provider can read and alter the collection |
| `EncryptedSegmentsV1` | Visible `NV Data/v1` encrypted segments, encrypted snapshots, and wrapped-key descriptors | Live store; encrypted durable segments, derived current rows and private local state | Note data and private metadata are concealed from a provider without the key |

The feature that stores notes as separate text files remains supported. Encrypted mode cannot place plaintext note files, plaintext `Notes & Settings`, note-title filenames, or plaintext temporary exports inside its provider folder. Its first implementation uses segments as the provider representation and the existing explicit export/external-editor facilities for plaintext access. A continuously maintained local plaintext working directory and encrypted one-file-per-note projections are optional later features, not prerequisites for encrypted sync.

`PlaintextFilesV1` supports plaintext text-file interoperability as proposal 4 does. Encrypted segments must preserve the note data supported by their declared content codec, including existing supported rich text; migration must reject or explicitly disclose any unsupported conversion before committing. Enabling encryption must not silently flatten a rich note.

Current work follows the [input/content scope](../iCloud-Drive-Support-Spec.md#input-and-content-scope): use standard AppKit input handling and NV's existing capture timing; investigate properly registered external undo edits before any coarser fallback. Attachments are out of scope. New codec/generator work starts with plaintext; RTF/HTML work is paused pending a separate retain/remove decision, without dropping legacy recovery or silently converting existing data. Set remaining limits from practical whole-note editing/memory measurements with wire headroom, while keeping long-history processing bounded independently of current-note size.

The two profiles share the operation model and transport code. Profile and codec requirements are immutable collection-bootstrap facts. A mode change creates a fresh collection through the controlled migration flow; it is not inferred from a filename extension, provider classification, or a remote preference update.

### Required history features

Both segment profiles include these features, in this implementation order:

1. **Per-note history, selective recovery, and Recently Deleted.** Preview retained local and remote revisions; copy a selected passage, restore explicitly selected fields, recover a separate note, or restore a deleted note under a fresh birth. This is NV's recorded history, not enumeration of Apple's historical file versions.
2. **Conservative automatic field/text merging with an inspectable result.** Merge compatible changes against a verified common base using the pinned `NVConservativeMergeV1` rules. Preserve every input and show the resulting merge in history; ambiguous cases keep the existing conflict-resolution path.
3. **Portable causal undo/redo of meaningful actions.** Derive saved-edit and named-action eligibility from validated repository action records in the requested note/collection scope. A unique causally maximal applicable action may be undone on any Mac; concurrent/overlapping candidates require review rather than arrival-time ordering. Undo/Redo append compensating operations. Exact cross-device typing undo is not included.

These are required proposal-5 work, not optional follow-ons. The [protocol rules](Protocol.md#action-records-and-cross-launch-undo) and [UI contract](Implementation.md#history-recently-deleted-and-cross-launch-undo) define their limits. No extra provider directory, mutable undo log, shared cursor, or per-note sidecar is introduced. Full-history search and named collection restore points remain deferred. Portable Command-Z is a causal candidate view, not one linear cross-Mac stack.

The [native undo experiments](Native-Undo-Experiments.md) test implementation candidates for this feature on macOS 14/26 and in two bounded models. They distinguish demonstrated span accounting from unimplemented Cocoa/segment integration and unaccepted UX compromises.

The adopted [invocation-scoped review](Implementation.md#invocation-scoped-undoredo-review) reuses the conflict resolver presentation. It also disambiguates incomparable portable candidates. Apply Undo/Redo completes the captured command and selected candidate; explicit history recovery and conflict-badge choices remain independent actions. Cancellation consumes nothing, and the inverse reverses the actual approved change. Sharing a view never changes action ancestry/scope or grants provider disposition authority.

## Decisions made concrete in this proposal

1. **One durable representation for note changes.** Every captured mutation becomes part of a self-contained immutable segment installed locally before it is eligible for publication. There is no new append-only WAL, WAL-to-segment translation, mutable active cloud log, or crash-time sealing of partial provider files.
2. **The live model remains authoritative during use.** Mutation admission updates it immediately. Admission is distinct from durable segment installation, just as existing pending writes are distinct from a completed barrier. A durability failure suspends further mutation without rolling back admitted text.
3. **Current-row startup is derived, not a second history store.** Complete values and compact authoring context represent an exact local acceptance prefix. Indexed catch-up and one consistent current-row capture support fast launch without reading unbounded history. There is no packed startup cache. Required preferences, association and retained-history evidence are independently owned private state.
4. **Explicit logical operations carry intent.** A validated `Delete` operation identifies a note birth. File absence alone does not manufacture that command. Unexplained external disappearance retains NV's confirmation preference on either Mac.
5. **History supplies committed identity.** Ordinary creations use a new note UUID. Restoration and undo of deletion create a new birth/UUID. The proposed deterministic path-slot co-add optimization is disabled pending its own model/vectors and adoption decision; v1 does not silently unify independent imports by name/content. Ambiguous cases preserve both records or await explicit association.
6. **Separate files are an editable projection.** Associated external edits enter the live model, become durable segments, and propagate. A bounded advisory projection xattr identifies represented revisions and delayed dependencies without assuming atomic delivery or permanent identity. Ordinary eligible external additions import automatically; specific provenance exceptions and narrowly plausible broken relationships require waiting/review. Missing metadata alone does not prompt. A quiet catalog is not proof of global newness; late independent imports remain separate. No portable Apple identifier is required.
7. **Immutable names replace shared refs.** There is no mutable `HEAD`, shared database installer, shared sequence counter, acknowledgment registry, membership list, or newest-checkpoint election. Per-writer directory names are random epochs, not computer names.
8. **No initial garbage collection of history.** Provider segments and local accepted/sealed segments are retained. Snapshots accelerate reading but do not permit pruning causal history, deletion evidence, or retry bytes. This deliberately costs disk space and provider file count.
9. **Encrypted mode authenticates before interpreting.** Use AES-256-GCM and HKDF through CryptoKit, and a reviewed Argon2id implementation for passphrase wrapping. The existing CBC/CRC format is a legacy input, not the new wire format. The detailed protocol needs cryptographic review before release.
10. **Provider failure is not global edit failure.** Local segment durability can continue while uploads, downloads, remote key descriptors, projection writes, or provider conflict queries are unavailable. Loss of the local durable store, an unavailable key for a new local write, or lifecycle quiescing independently closes the edit-admission gate.
11. **History is user-accessible, not history rewriting.** Recovery and undo append new changes. Automatic merges retain their exact inputs, and deleting a note or text does not erase those inputs from history. Recently Deleted offers Restore alone: after local durability it removes the source entry from the default list while retaining history/provenance. Later deletion of the restored fresh birth creates a new entry, not revival of the old one. There is no automatic expiry or permanent-delete control in v1.
12. **The repository data directory is visible.** Use the literal ordinary directory `NV Data`, not `.nv-sync`, a hidden alias, or a Finder package. It contains required collection history, not expendable sync metadata. Segment collections create no `Notes & Settings` in either their provider folder or private local store.
13. **Ordinary edits affect Current only.** Note predecessors name Current's represented inputs, not all causal knowledge. Unresolved alternatives and separate conflict notes survive normal body/title/label/format edits; explicit resolver choices have their own captured scope.
14. **Automatic preservation follows causal evidence, not delivery order.** Any applicable Delete covering E removes the reason for an untouched automatic E copy, even if another Delete was concurrent with E. A concurrent uncovered extension F and independent user work remain protected. No automatic copy/retirement operation makes a transient view permanent.
15. **Repository Save As preserves history.** Copy the available `NV Data` and associated text files with their identities and exact history intact. Application Support, unpublished work and waiting for other Macs are not prerequisites. Current-state-only fresh-genesis/legacy export is a separately labeled operation.
16. **Repository and private-store repair is bidirectional, automatic where locally decidable, and evidence-preserving.** The selected folder is the user's repository; Application Support is NV-managed durability and offline buffering. Exact validated copies repair missing counterparts. Positively same-root missing `NV Data` entries are rebuilt transparently from complete private history; occupied damaged entries remain in place and offer Save As. No Restore control exists. **Work Offline** is offered only during startup for already positively disclosed newer or required provider evidence missing locally. An active healthy session keeps editing as later evidence arrives. Rebuilding a damaged private store uses a fresh sibling local-store ID and a durable retained-history pin before activation. No repair overwrites a race winner or claims undisclosed branches.
17. **Saving an NV conflict separately does not choose the original's contents.** `RecoverCopy` acknowledges only the selected revision after durable preservation. Current still comes from normal source-head reduction, not the list of remaining unresolved entries. Reciprocal copies may leave the original plus two recovered notes, including duplicate text; none implicitly deletes/rewrites the source. Use this version remains the explicit source-body choice. Completed copy dispositions survive later copy edits/deletion; new uncopied descendants remain reviewable. Apple's separate selected-member rules do not change.
18. **External-file review is targeted and recoverable.** Offer only live notes with a repair-needed relationship and their own matching active filename or exact nonempty contents; unfinished transitions retain their last accepted projection as a temporary comparison input. Association preserves identity and separately reconciles contents. Dismissal defers; it does not import or abandon. Retain one latest verified pending snapshot plus exact admitted inputs privately, never every external save. Persist retry reservations and recover committed imports before rescanning so a crash cannot repeatedly create the same note. FSEvents hints prioritize checks but cannot cause a question or override their outcome.

The principal compromises are explicit: immutable provider files and retained history grow without bound initially; no proof that a provider disclosed its newest data; and conservative handling of external copies/restorations that have identical observable contents. The private database avoids requiring one local filesystem object per segment. The protocol does not claim to solve the indistinguishability cases in the [identity experiments](../tla/Protocol-Combination-Experiments.md).

## Storage ownership

Use Foundation's user-domain Application Support location. For a segment collection, allocate a fresh random `localStoreID` and retain a positively validated bookmark association to the selected root. A matching `collectionID` alone never silently attaches a different physical folder or authorizes filesystem operations.

```text
Application Support/Notational Velocity/Collections/<localStoreID>/
    Collection.sqlite                  exact history, required private state, current rows
    Collection.sqlite-wal / -shm        SQLite-owned sidecars when present; never sync transport
    unlock/<descriptorID>.nvkey         encrypted profile's nonsecret wrapped-key descriptors

Application Support/Notational Velocity/Collections/
    selection-<associationID>.nvlocal   active-store locator, not a history watermark

Selected provider folder/
    Title.txt                           PlaintextFilesV1 only
    Another title.txt                   PlaintextFilesV1 only
    NV Data/v1/                         visible; include in collection backups
        keys/<descriptorID>.nvkey
        segments/<writerEpoch>/<sequence>-<segmentID>.nvseg
```

Local State is a required logical role in the private database: association, bootstrap/retained-history pins, preferences/UI state and file-association receipts. Exact immutable history acceptance and pin advancement commit together. Note revisions and `ActionRecordV1` values—including origin provenance, scope parents and compensation/redo relationships—remain portable history and rebuild causal Undo/Redo after private-state loss. Only transient native typing groups/selections are lost. Credentials and physical association require their independent validated local bootstrap; database content alone never grants root authority. Provider descriptors keep their existing public/encrypted suites. **Provider snapshots** are immutable roots/pages in the provider segment namespace; private current rows are derived from validated accepted history, never adopted directly from a received snapshot.

Use `0700` directories and `0600` local files where supported. The database is not expendable or backup-excluded; it may contain the sole copy of unpublished work after clean quit. Its derived current rows do not change that classification. Use a consistent SQLite backup, not a main-file-only copy with a live journal. Keep all private storage in Application Support; never place SQLite/WAL/SHM in the provider folder.

The [LocalStore contract](LocalStore.md) maps these roles to one SQLCipher database. Password-free stores use a documented nonsecret key, not Keychain-dependent confidentiality; encrypted database keys derive from CK and use existing password descriptors. Pending payload/reference replacement is transactional; current rows and compact authoring context support startup directly; historical indexes remain lazily accessible without embedding all history in current rows. Private buffers survive ordinary close/root switch and are never synced history. Neither a derived view nor a receipt authorizes deleting history. Production SQLCipher, credential and recovery qualification remain gates; the design's adoption is not a claim that the runtime already exists.

### What to back up

The UI/help must distinguish these roles explicitly:

| Copy | What it preserves and what it omits |
| --- | --- |
| Entire selected collection folder, including `NV Data` and its actual downloaded contents | The history/key descriptors actually present there, plus plaintext working files where enabled. Text files alone omit identities, deletion intent, history and persistent actions; encrypted collections have no plaintext substitute. |
| This Mac's complete Application Support segment store | Locally retained history, including unpublished changes, private settings/association, and pending external recovery snapshots. Restore must revalidate location/ownership and allocate a fresh writer epoch; copying an association/reservation does not authorize a new root or replay consent. |
| Explicit epoch-4 export | A separate current-state legacy collection, not a history-preserving repository backup or live old-client mirror. |

`NV Data` must be visible with Finder's ordinary hidden-files setting and participate in Select All; do not set invisible flags or hide it through package presentation. Reserve that exact name against note import/export and unrelated bootstrap targets. Never overwrite an existing unrelated item at that name. This is the first unpublished segment layout, so no hidden compatibility alias or automatic on-disk migration is needed.

**The selected folder alone is adequate input for a full repository copy of everything published there.** Preserve all available `NV Data` contents and associated text files, including unknown/unimported files; do not require source Application Support to copy that repository. The private store may temporarily contain newer unpublished work, so the UI must distinguish **Saved on this Mac** from **Published to the Repository**. When an active-session recovery Save As is intended to preserve the latest local work, first complete its local barrier and include the validated repair union; do not silently omit that work or mislabel a provider-only copy as current. Save As must preserve history/identities, not synthesize a current-state-only genesis. See the [copy/export contract](Implementation.md#repository-copy-versus-current-notes-export).

Visibility prevents accidental omission; it does not establish global freshness or make a placeholder readable. Obtain actual bytes for the captured inventory and report unavailable/changed items; an incomplete known dependency set can be copied/preserved even though editable recovery must wait for repair. Do not call that subset a validated complete history closure. Neither another Mac's availability nor provider-reported upload is required for copying local repository bytes. Explain local publication versus cloud upload separately without expanding the repository-copy contract into a backup of all application state. Encrypted recovery requires a usable passphrase/recovery key; a device-bound remembered key need not travel with the copy.

## Durability and authority boundaries

| Boundary | Evidence | Claim |
| --- | --- | --- |
| Admitted | Live mutation plus existing pending UUID/LSN generation | Visible in this process; not yet crash durable |
| Locally durable/accepted | Complete validated segment/parent closure and qualified atomic SQL retention/acceptance/pin commit | Exact committed operations recover after ordinary same-Mac crash; positively discovered pinned loss invokes repair, without claiming every old byte is reread on launch |
| Installed at provider root | Exact same envelope coordinately installed and verified in the local provider namespace | Handed to the provider; not proof of remote storage or receipt |
| Provider reports uploaded | Advisory status for that item | Progress reported by that provider; no global visibility guarantee |
| Received by another NV | That NV authenticates/validates and locally persists the dependency closure | That recipient can reconstruct the operations; v1 does not publish acknowledgments |

For sync note state, durable local history supplies recovery evidence; current materialization and causal-undo indexes are entirely derived. Local State separately owns host-private settings/association that note operations intentionally do not encode. Reconstructing invalid materialization can cost launch/index time, but must not reset settings, invent a root association, suppress a durable note/action operation, or remove a portable undo candidate. “Checkpoint” in the segment models abstracts derived current materialization, not the legacy authoritative `Notes & Settings` archive.

## Changes relative to proposal 4

| Existing area | Proposal-5 treatment and adoption work |
| --- | --- |
| Live model, synchronous search | Preserve. New worker inputs are immutable values; AppKit publication remains fenced and main-thread-only. |
| `AUTH-01`, `ROOT-01`, `WAIT-01` | Preserve positive-only root/provider evidence, continuous local directory-lock ownership, explicit root recovery choices, and no timeout-based correctness. Add local segment-store association checks. |
| `START-01` | Replace provider-current shared-checkpoint startup with a complete local snapshot/segment view or a dependency-closed bootstrap. Never describe either as globally latest. |
| `DISC-01`, `PUB-01` | Preserve the current-file double-catalog fence for plaintext projection changes. Add independent monotonic discovery of immutable segments and causal publication rules. |
| `REC-01` | Preserve the badge-invoked editor swap and Apple-version disposition scope. Replace the WAL barrier with a local segment barrier; an Apple version additionally needs its exact plaintext file installation. Segment history is a separate source of conflict state. |
| `DUR-01`, `CLEAN-01` | Replace active WAL cleanup with local segment installation. Checkpoints never retire history. Cleanup covers owned disposable staging and specifically unreferenced/released pending-file buffers, never referenced snapshots or operation inputs; whole-collection removal requires separate authority. |
| `CKPT-01` | Shared `Notes & Settings` CAS/three-input closing merge is absent in segment collections. Private SQLite transactions replace separate Local State installers; materialization failure cannot retract accepted history or required-state commits. Provider/projection and legacy/export callers retain their independent safe-replacement contracts. |
| ADR-0001/0003/0014 | Change routine cross-Mac authority to explicit segment operations; separate files remain interoperable inputs/outputs. Add encrypted mode and distinguish unknown external disappearance from a committed deletion. |
| ADR-0002/0004/0005/0008 | Revise startup, file/checkpoint ordering, legacy compatibility, and quit to the new local durability boundaries. |
| ADR-0006/0007/0009/0013 | Retire their active mutable-WAL requirements only for segment collections; retain legacy decoding/migration and positive local artifact association. |
| ADR-0010/0011/0012 | Retain independent local/provider execution, controlled credential cutover, and no Spotlight correctness dependency, with segment-specific refinements. |
| Compact retired conflict UUID set | Carry its semantics into authenticated operations and snapshots. Ordinary committed births also have retained explicit deletion history; legacy `syncServicesMD` supplies no acknowledgment or retention rule. |
| History, automatic merge, and undo | Add app-owned history/Recently Deleted, the pinned conservative merge policy, and portable causal action undo. `ActionRecordV1` gains per-scope causal parents; origin is synced provenance, not eligibility ownership. Revise the current vocabulary's exclusion of historical browsing only for the new NV-history view; retain the distinct Apple resolver's API/disposition restrictions. |
| Startup format, visibility, backup and ADR-0005 | New segment collections use private current rows and visible `NV Data`; retain `Notes & Settings` naming/epoch-4 serialization only for legacy stores and explicit exports. Update backup guidance to identify retained history and unpublished local work. |
| Existing TLA+ claims | Reuse valid component obligations; do not cite current-visible/checkpoint models as proving the new segment protocol. [Verification](Verification.md) specifies the replacements and bridges. |

The normative adoption is recorded in the specification, rewritten ADRs, vocabulary and model README. The table above explains the migration boundary, not remaining authority for proposal 4. Before production enablement complete the concrete release and integration gates in Verification; adoption is not proof of implementation readiness.

## Legacy compatibility and migration boundary

The last public release was in 2011 and used epoch-4 Notes & Settings. No epoch-5, segment, NVStorage or private SQLite format has shipped. Plan/proposal edition numbers and development encoding revisions do not establish a compatibility obligation. Revise current unreleased encodings directly and remove superseded draft readers instead of maintaining migrations solely for those drafts. Continue opening legacy epoch-4 collections and recovering their legacy journals through the existing compatibility path. Retain the epoch-4 serializer and compatibility test only for legacy collections and explicit legacy-format export. The new current-row formats, private local state, operation representation and routine saves have no epoch-4-readability requirement and need not instantiate `FrozenNotation` archives. The export writes a genuine `Notes & Settings` at its separately chosen destination, where an old app expects it; it excludes new history/undo protocol metadata that epoch 4 cannot represent.

The new provider folder itself is not an epoch-4 synchronization store. Do not maintain a compatibility archive in Application Support or a continuously updated shared `Notes & Settings`: neither supplies useful old-client access to this protocol, and the latter reintroduces conflicting authority and an encrypted-mode plaintext leak. Compatibility means legacy opening and explicit export, not direct opening of the new repository by old NV or safe mixed-version writers.

Initial migration creates and verifies a new destination; it does not rewrite the source directory in place. This also prevents an old running NV instance from continuing to mutate a newly converted shared checkpoint. A detected legacy writer or foreign database appearing later is external data to preserve and report, not authority to reinterpret the segment collection.

## Implementation completion criteria

Deliver both profiles using one operation reducer and segment codec, with no active v5 WAL, plus all three required history features above. Existing text editing, synchronous search, session typing undo, external editing, safe replacement, and legacy opening must remain tested. Encrypted bootstrap must work between Intel and Apple Silicon Macs using only the selected provider folder and a user-entered secret. Cross-Mac tests must cover reordered and duplicated segments/files, crash before/after each local installation/pin/repair boundary, interrupted bootstrap, partial/total loss of either copy, automatic/conflicting edits, intentional and unexplained deletions, selective recovery, and cross-launch compensation.

The [Verification](Verification.md) report separates executed model checks from planned implementation/API tests. Existing passing tests are evidence for their documented boundaries only. Shipping requires concrete codecs and state-machine tests, bounded nonvacuous model checks, and live API observations; writing this proposal does not satisfy those gates.
