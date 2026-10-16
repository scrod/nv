# Phase 6 — Plaintext projection and pending-file recovery

Status: **implementation begun**. This document defines the complete work;
executed evidence belongs to the increment ledgers. The first P6.1 slice is the
[advisory stamp codec](phase6/01-projection-record-contract.md), with its
[qualification and remaining gates](phase6/01-projection-record-validation.md).
The next slice adds [exact filenames and descriptor values](phase6/02-projection-descriptor-contract.md),
with [separate qualification](phase6/02-projection-descriptor-validation.md).
The third slice implements [history-checked private output and accepted/intended
observations](phase6/03-history-observation-contract.md), with its own
[failure and compiler-boundary evidence](phase6/03-history-observation-validation.md).
The fourth slice adds [captured filename preparation](phase6/04-filename-preparation-contract.md)
and [qualification](phase6/04-filename-preparation-validation.md). The
[text-encoding investigation](phase6/05-text-encoding-investigation.md) records
remaining portability failures without changing the output policy.
The [standalone history reader](phase6/07-inbound-history-contract.md) adds accepted
source validation while keeping file-byte and unique-association checks separate.
The [portable Changes section](phase6/08-portable-projection-contract.md) adds
canonical placement and complete source validation at actual acceptance.
The [exact-output increment](phase6/09-exact-output-contract.md) retains actual
native-encoded bytes with their private intent and preserves UTF-8 promotion;
its [qualification](phase6/09-exact-output-validation.md) separates conversion,
recovery and remaining settlement-owner release.
The [complete query](phase6/10-complete-binding-query-contract.md) and
[local portable producer](phase6/11-projection-producer-contract.md) use checked
source/observation captures and exact-byte retry. Inbound physical applicability
and rooted receipt issuance retain their later gates; the [P6.1 completion ledger](phase6/06-completion-ledger.md)
separates implemented contracts from remaining work and later physical consumers.
The [retention follow-up](phase6/12-projection-retention-validation.md) reuses the
accepted dependency graph to bound sequential-description startup leaves, with
concurrent-tip, final-recheck, crash and work-count witnesses.
Follow the dependency order below, completing each production slice and its
failure companions before expanding it.

## 1. Outcome, authorities and boundaries

Deliver a headless production path connecting the checked collection to editable
separate files:

**durable note history → exact file output → coherent external observation →
admission or targeted review → durable history/association → fresh-process recovery.**

An ordinary new external text file imports automatically when the adopted
exceptions and repair-candidate checks permit it. Existing external edits retain
their contents through races. Unexplained disappearance follows the deletion
confirmation preference; a committed NV Delete retains its distinct meaning.
Restart cannot duplicate an already admitted import, replay consent or turn an
old filename into removal permission. Healthy notes become editable before an
unrelated file/provider backlog settles.

Read these sources together:

- [Normative separate-file policy](../../iCloud-Drive-Support-Spec.md#separate-plaintext-files),
  [Protocol: separate files](../Protocol.md#separate-text-files-and-the-identity-limit),
  [decision matrix](../Protocol.md#current-file-decision-matrix),
  [pending commit/recovery](../Protocol.md#pending-file-commit-and-recovery-records),
  and [implementation adaptations](../Implementation.md#external-file-admission-and-pending-decisions).
- [CONTEXT.md](../../../CONTEXT.md), ADRs
  [0006](../../adr/0006-retain-positive-association-and-directory-ownership.md)
  and [0014](../../adr/0014-distinguish-logical-deletion-projections-and-conflict-disposition.md),
  and the [TLA+ coverage guide](../../tla/README.md).
- [Conformance strategy](swift-storage-conformance-testing-strategy.md),
  [language boundaries](swift-storage-library-proposal-v2.md),
  [private record contract](private-record-contract.md), and
  [remaining encodings](../Format-TODO.md#8-plaintext-projection-metadata).
- [Foundation replacement contract](../../Foundation-Safe-Replacement-Migration.md),
  [Apple API evidence](../../Apple-API-Contract-Validation.md),
  [Phase 5 test families](phase5-provider-root-testing-plan.md), and
  [P5.7 qualification](phase5/07-connected-qualification-validation.md).

This is Swift roadmap Phase 6; the broad proposal's older work-package numbering
is different. Phase 7 owns actual AppKit/Objective-C admission, deletion prompts,
pending-file presentation, external-editor launch, native undo, resolver and quit
integration. Here, test the same contracts through a headless host, without
changing search, typing, selection, responder routing or UI scheduling.

Keep the established policies: co-add and UUID aliases remain disabled; FSEvents
only prioritizes inspection; xattrs remain advisory; attachments and new rich-text
codecs remain out of scope. Preserve legacy supported formats through their
existing path and return explicit unsupported outcomes from an unimplemented new
codec. Encrypted collections publish encrypted history, with no continuously
maintained plaintext provider projection.

**Replacement policies have different scopes.** P5.6 stops and offers Save As for
occupied damaged `NV Data` entries. Ordinary mutable note saves still follow the
Foundation plan's expected-snapshot replacement, displaced-content preservation
and reconciliation requirements. Applying either rule to the other's caller
would change the adopted policy. Any newly demonstrated inability to meet that
contract is an explicit capability/policy gate, not permission to weaken a check.

## 2. Dependency order and completion gates

| Increment | Requires | Production result and exit gate |
| --- | --- | --- |
| P6.0 — inventory and contract map | P5.7 baseline | Exact source/format/state ownership and reusable evidence identified; independent observers and first failure schedules ready |
| P6.1 — values, metadata and evidence | P6.0 | Complete projection/stamp/private-record layouts, bounded decoders, independent fixtures and restricted issuers |
| P6.2 — physical mutable-file operations | P6.1 | Real read/create/replace/move/remove paths with exact outcomes, preservation and native capability qualification |
| P6.3 — coherent catalog and classification | P6.1; P6.2 read path | Read-only production classifier matches the adopted decision matrix under races, with bounded work and no early publication |
| P6.4 — history-to-file transitions | P6.2–P6.3 | Initial output and A→B→C save/rename transitions settle exact generations and source obligations through restart |
| P6.5 — pending import and association | P6.3–P6.4 | Automatic import and explicit identity/content choices use retained inputs, exact retry identities and checked physical settlement |
| P6.6 — edits, absence and lifecycle | P6.4–P6.5 | Associated external edits, confirmation/Restore/Delete and combined repair decisions compose with history and local saves |
| P6.7 — connected qualification | All above | Actual consumers pass joined process, filesystem, provider, performance, privacy and language-boundary checks; Phase 7 handoff is explicit |

Within each increment, deliver a small end-to-end success case, near-valid
failure cases, then interruption/recovery. P6.2 first qualifies read and exclusive
creation before replacement. P6.5 first closes one automatic import across a
crash before adding the multi-choice association cases. Cross-platform/source
checks run with the affected increments, rather than first appearing at P6.7.

## 3. Source architecture and state budget

Reuse `NVStorageCore` for canonical passive values and deterministic decisions,
`NVStorageRuntime` for collection-owned admission/private transactions, and the
existing rooted/platform adapters for physical operations. Keep one collection
owner and one root owner with their existing bounded execution resources. A
small collection-owned reconciliation worker may coalesce dirty work; it must
reuse the existing reservation, lifecycle and continuation patterns rather than
create an actor per note or a general workflow framework.

### 3.1 Existing pieces and the remaining connection

- `PlaintextNoteValue.swift` stores title, body, labels and display timestamps.
  The separate descriptor and history-binding layouts now exist. Their private
  output consumer checks accepted occurrences and current provenance. P6.1 now
  retains and receives complete bindings in Changes objects; P6.2's physical
  consumers and P6.4's receipt settlement remain separate gates.
- `PendingFiles.swift` already retains latest/frozen inputs, reserves identities,
  checks committed operations and transactionally settles private references.
  Its `preparePendingAssociation` prepares a particular pending value; it is not
  the complete identity/content-choice interface in the protocol.
- `completePendingAssociation` currently obtains a passive platform record from
  a synchronous callback on the database lane. Its tests establish private-state
  ordering, not production filesystem observation. Replace/refine that seam for
  the production caller: do rooted I/O on the root resource, return narrow issued
  evidence, and consume it under final collection checks. A blocking coordinator
  accessor must never run inside a SQLite transaction or that callback.
- `NotationDirectoryManager.m` supplies the coherent preparation/second-catalog
  fence and detached mutation pattern. Reuse its semantics, not its legacy
  decoded-body-as-identity fallback. `DeletionManager.m` supplies preference and
  missing-note behavior; the new headless admission must distinguish an external
  absence from incoming causal Delete before later UI integration.
- Phase 5 supplies root ownership, bounded native metadata batches, batched hint
  lookups, dedicated coordination, lifecycle fences and immutable transport.
  Its incomplete/discovery listing is not a complete plaintext deletion catalog,
  and its immutable install receipt is not mutable-file replacement evidence.

### 3.2 Minimal state

| State | Owner / lifetime | Rule |
| --- | --- | --- |
| Captured catalog, selected reads, candidate comparisons | One bounded reconciliation attempt | Immutable capture; reuse cheap bulk metadata, discard/recompute stale preparation |
| Intended and last accepted projection | Collection; required private association state where restart needs it | Exact path/format/bytes or reconstructible represented value, generations and source accounting; only the active transition's previous representation remains a matching clue |
| Physical expected snapshot / entered operation | Root owner; one live attempt | Newly checked for each effect and after restart; persisted receipts describe earlier observations |
| Latest pending preview, admitted input references, reservation, settlement | Existing private pending records/SQLite transactions | Latest is replaceable; each unfinished admitted operation independently retains its exact input |
| Provisional relationship claim | Collection admission/relationship generation | Publish with the admitted mutation; recover durable work from existing history/reservations and acquire fresh physical evidence |
| Dirty/revisit state and continuations | Existing worker lifecycle, plus required pending records | Coalesce signals; retain unfinished work; progress after finite interference stops |

No new synced metadata directory, sidecar, auxiliary journal, historical
filesystem-event database or long-lived history-validation cache. Reuse current
rows, accepted history and private state. If a missing indexed lookup is measured,
add a derived index with explicit schema qualification; do not scan unbounded
history on every file event. Avoid persisting derivable duplicate bodies outside
the already required pending payload ownership.

### 3.3 Language-backed boundaries

The following are roles, not prescribed public type names. Prefer refining
existing types over adding parallel wrappers.

| Role | Issuer and consumer | Static and dynamic enforcement |
| --- | --- | --- |
| Validated direct-child projection name | Canonical/name-policy validator → rooted adapter | Nominal type distinct from arbitrary path and immutable repository locator; reject reserved names and traversal |
| Passive parsed stamp/descriptor | Bounded codec → history/provenance validator | Parsing yields claims; only validated exact represented history can issue association evidence |
| Coherent observation / reconciliation input | Root catalog/read owner plus captured model context → pure classifier | Restricted immutable construction; bind root, attempt, catalog, note/relationship and history/view context |
| Prepared decision | Classifier → collection admission | Exhaustive enum for automatic import, known association/edit, wait, review, ambiguity, absence and retry/unsupported; only eligible variants can reach their respective admission methods |
| Captured content choice | Collection admission → ordinary action or neutral repair | Closed neutral/changed variants; changed carries exact before/after and causal scope, neutral carries existing Current evidence |
| Prepared physical transition | Collection history barrier + root checks → mutable-file adapter | Distinct create/replace/move/remove inputs; issuer-restricted, operation/context-bound evidence; no Boolean “safe to overwrite” |
| Verified physical result | Root owner → receipt settlement | Distinguish installed, installed-needs-reconciliation, stale/no-effect and failed/uncertain; bind exact generation and source accounting |
| Pending settlement | Local transaction owner → subsequent scans/host | Receipt and pending-reference changes commit together; decoded old records need fresh physical validation before any new effect |

Keep fields immutable and `Sendable`, with private/file-private initializers at
real validation boundaries. Compile-test ordinary clients and same-module
forgeries. Do not make evidence publicly constructible through `Codable`, test
factories, bridge wrappers or writable fields. Actor isolation checks ownership;
final generation checks still handle reentrancy and external mutation. Reserve
work before suspension; each SQLite transaction stays synchronous. Use unique
ownership for descriptors/stages only where it simplifies their actual lifetime;
immutable history and captured bytes remain shareable.

Filesystem observation and private settlement are separate operations, not one
cross-resource atomic transaction. A later external change is subsequent work.
On uncertainty, preserve input and dirty obligations rather than promoting an old
observation into current write permission.

## 4. P6.0 — Establish the concrete contract and evidence baseline

1. Inventory the actual root, private-record, admission and native replacement
   callers. Record requirement → issuer → consumer → source → positive/failure
   witness in a small phase ledger. Verify every promise against the spec,
   Protocol, glossary and corresponding model; do not infer semantics from names.
2. Record the P5.7 source/dependency/compiler/harness baseline and reviewed reuse
   scope. List the production seams still represented only by test callbacks.
3. Map every needed field to existing state before extending a record. Complete
   the remaining descriptor/stamp/receipt definitions from `Format-TODO.md`:
   profile presence, represented revision/merge/automatic-source references,
   encoding/filename, raw metadata presence, digest and consumer context.
   Decide concrete segment placement and field participation together with the
   identity/hash callers; optional projection metadata must not accidentally
   become physical authority or silently change note/merge identity rules.
4. Inventory filename collision adjustment, encoding fallback, absent-versus-empty
   tags, permissions and date behavior from the legacy callers. Capture expected
   results independently before extracting helpers. Defer unsupported rich
   codecs explicitly rather than guessing their output.
5. Build the first independent observer and reached-boundary hooks around actual
   reads/private commits. Reuse existing child process, SQL observer, fault and
   strict test runners. Keep test-only scheduling below the authority issuer.

**Exit:** each new field has a purpose and owner; adopted semantics are explicit;
the first import/replacement crash cases have independent expected results. A
genuine policy ambiguity or native capability failure is brought to the user
before implementation changes behavior. Format completion itself needs no new
compatibility branch: all segment/private drafts remain unreleased.

## 5. P6.1 — Freeze canonical projection and observation records

Implement the complete current v1 layouts and independent byte fixtures before
production writes. Extend the existing record/limit registry and consumer
validation, rather than inventing a separate serializer.

- Direct-child names use NV's actual collision/filename policy. Reject NUL,
  separators, `.`/`..`, reserved protocol/database names and unsafe traversal.
  Keep exact actual filename distinct from title. Case/normalization ambiguity
  stays an explicit classification even on a case-sensitive volume.
- Define portable projection descriptors separately from local physical
  observations. Freeze their profile/absence and canonical identity rules with
  tests for every field; descriptor presence cannot certify installation.
- Implement `NVProjectionStampV1` at exactly
  `org.notationalvelocity.projection#S`: collection, birth, format, exact byte
  digest and complete ordinary/equal-value/merge/automatic-preservation references.
  Sorted sets, exact locators, tags and limits need literal independent vectors.
  The 4-KiB bound is inclusive as specified; oversized complete references cause
  omission/reporting, never a truncated causal set or an extra file.
- Preserve raw observed encoding/tags/dates and their presence separately from
  values filled in for import. Fallback labels/text cannot become evidence that
  the file matched a particular candidate. Empty body is supported; BOM/framing
  alone does not satisfy the nonempty-body repair heuristic.
- Complete private accepted/intended/settlement observation codecs under the
  existing required-private-state mechanism. Persist exact referenced inputs and
  source obligations; serialize descriptions, not live filesystem capabilities.
  Extend pending codecs only where the actual content-choice contract requires
  it, preserving latest/frozen ownership and unsupported/corrupt classifications.
  The [frozen-output implementation](phase6/13-frozen-output-contract.md) now
  retains one serialized transition independently of the latest intention and
  releases superseded unowned chunks atomically. The [settlement record mapping](phase6/14-settlement-record-contract.md)
  retains exact consumed decisions and describes projection-owner transfer;
  fresh physical receipt publication remains a later rooted consumer.

**Tests / exit:** independent encoders/decoders and preimages; valid/invalid field
participation; below/at/above bounds; overflow/truncation; duplicate or unordered
references; wrong collection/profile/kind; metadata presence; filename Unicode,
case and collision adjustment. Exercise real history validation for all stamp
variants, including a complete reference that exceeds 4 KiB. Test both encrypted
private-store profiles, while denying plaintext-provider output in encrypted
mode. Update current fixtures/schema directly; retain epoch-4 compatibility tests
where shared code is affected. No ambiguous draft version fallback is added.

## 6. P6.2 — Qualify actual mutable-file operations

The [rooted adapter contract](phase6/15-rooted-mutable-files-contract.md) and
[qualification ledger](phase6/15-rooted-mutable-files-validation.md) track the
integrated coherent-read slice, native exclusive-creation primitive and remaining
physical/Swift-consumer gates separately. Recorded creation and direct-removal
qualification includes actual faults, namespace races, process exits,
history-issued Swift consumers, OS stage acquisition and Mac/Linux
sanitizer/negative controls. Claimed filesystem/provider and actual-document
gates remain distinct; physical receipt settlement is retained for P6.4.
The rename/update bridge now uses a distinct history-issued input, original
descriptor lease, the existing per-birth durable attempt, exact completion
receipt and read-only three-name recovery. The current slot/layout is shared
with same-name replacement; its typed consumers remain distinct. Qualification
is recorded in the ledger rather than inferred from native success alone.

Implement a narrow rooted mutable-file adapter using the existing ownership,
coordination and execution infrastructure. Reuse/extract qualified helpers from
`NVRootedDirectory` where appropriate; keep one intended Foundation replacement
algorithm rather than another provider-specific variant. Preserve the legacy
caller until the migration contract's replacement gates pass. Changing that
caller triggers its full native/app/legacy qualification, not merely Swift tests.

1. **Read:** capture exact bytes and metadata through a checked descriptor under
   the existing root/current-file fences. Distinguish placeholder, permission,
   changed/missing item, unsupported encoding and interrupted read. Known empty
   bytes are a valid value; unavailable bytes are a different outcome.
2. **Create:** prepare exact encoded body and metadata in an owned, private,
   same-volume stage; install at an available validated leaf with exclusive
   creation semantics. A collision returns for re-observation/collision handling.
3. **Replace:** follow Foundation's operation-local directory-relative destination reference, staged
   source, coordination, retained backup and post-install descriptor checks.
   Read and compare the actual displaced item, not only the preflight target.
   Preserve mismatching displaced contents and report reconciliation needed.
   Construct the leaf with `fileURLWithPath:isDirectory:relativeToURL:` using the
   held directory reference, as qualified in the migration plan; a leaf-object
   reference or a flattened pathname fails one of the two relocation races.
   Coordinate this same-document content update with destination options `0`.
   `WritingForReplacing` can close another application's presenter and is for
   replacing a document with a different one, not ordinary content safe saves.
4. **Rename/update:** account for the destination installation and the captured
   source separately. Source cleanup consumes only the still-matching original
   snapshot. Return/new occupant, case-only rename and format transition are
   explicit cases; a destination success cannot silently certify source removal.
   Preserve the committed candidate after capture/restoration or uncertain
   effects. Early no-effect retirement requires that this operation never
   captured the original. Fresh restart inspection reports original/output/backup
   separately and restores no prior physical permission.
5. **Remove:** consume the original expected-snapshot operation after the exact
   Delete's local durability barrier. A history record, birth, filename, stamp or
   old receipt alone cannot enter this path. Interrupted work requires fresh
   checks; a remote Delete never starts a path/UUID cleanup sweep.
   Use one `.forDeleting` accessor for direct protected capture, comparison and
   removal; temporary recovery paths stay implementation details. The
   earlier two-step Runtime consumer is now replaced by this native adapter;
   qualify its permission/barrier/reservation/descriptor and recovery fences.
   Retain actual public-rename notifications. The
   [presenter matrix](phase6/15-rooted-mutable-files-validation.md#active-presenter-correction-and-single-accessor-deletion)
   covers dirty-save/refusal/keep-open behavior, incorrect grants, failed cleanup
   and later saves; actual `NSDocument` and provider qualification remain distinct.
6. **Finalize:** verify exact body plus mandatory encoding/tag metadata, optional
   stamp outcome and source accounting. Follow qualified permissions/unrelated
   xattrs/date preservation and the existing Finder-metadata policy. Failure of
   a mandatory readback remains failure/uncertainty, even if stamp writing is
   optional. Retain uncertain staging/displaced material under explicit ownership
   until safely accounted for.

Use exhaustive outcomes rather than success/error Booleans. A failed callback
after a namespace effect is not proof of no write. Note-file directory syncing
retains its stated filesystem contract and is separate from the SQLCipher
history barrier. No hardware-power-loss guarantee follows from killing a process.

**Tests / exit:** production syscall/Foundation consumers, independent bytes and
metadata, before/after effect failures, concurrent uncoordinated replacement,
observed backup-name collision/retirement, edited source, held accessor, root move/loss,
symlink/hard-link/wrong-kind/case collision, partial write, EIO/ENOSPC/permission failure,
failed backup preservation and repeated recovery. Show a successful companion
for each actual primitive. Place an uncoordinated namespace change specifically
between the last comparison and rename/removal; a fresh preflight check alone
does not establish an atomic expected-item operation. An uncovered check/use gap
is a capability blocker requiring investigation, not a passing removal test.
Backup names retain the Foundation migration's approved UUIDv4 uniqueness
assumption: check absence inside the accessor and burn any occupied candidate.
The deliberate injection of that exact private name after the check remains a
recorded API-limit experiment, outside this assumption. Target-file replacement
and actual displaced-content preservation remain required race checks.
Qualify mandatory metadata atomicity on APFS and the
supported behavior on other claimed filesystems before enabling replacement.
Preserve P5.4's explicit fresh-deep-HFS+ limitation; do not broaden it to reads
after a supported root move. Unsupported capability is reported, not repaired
by an unqualified fallback.

## 7. P6.3 — Build the coherent catalog and pure classifier

1. Capture checked current values, active projection state, relationship/structural
   generations and history/view context. Enumerate a complete shallow catalog;
   select coordinated reads, then obtain and compare the complete second catalog.
   Validate root and model inputs before publication. Partial enumeration,
   unreadability and placeholders retain dirty work and grant no absence evidence.
2. Exclude directories, `NV Data`, `Notes & Settings`, exact legacy recovery names
   and specifically owned hidden residue according to policy. Visible recovered
   files remain candidates. Hints, catalog continuation and empty immutable
   discovery passes cannot stand in for the plaintext completeness fence.
3. Reuse bounded bulk metadata decoding and batched private hints. Unique local
   IDs are volume/session scoped and require uniqueness on both sides. FSEvents
   prioritize exact inspection; lost/coalesced/asymmetric events take the same
   normal path. A hint alone neither restarts a valid pass nor raises a question.
4. Apply the Protocol's mandatory provenance/history/deletion exceptions as
   guards on automatic decisions. Established applicable association and unique
   validated represented history precede the narrow repair heuristic and fresh
   import, but cannot bypass positively contradictory evidence. A trustworthy
   association may handle a legitimate edit with a mismatching old stamp; an
   unassociated skewed/copied/foreign observation takes its specific review/wait
   path. Encode these distinctions explicitly rather than an early-match shortcut.
5. Offer each live repair-needed note only for its own active actual path OR exact
   nonempty encoded contents. Last accepted output remains eligible only while
   its transition is unfinished. A healthy relationship, placeholder, initial
   owed write or unrelated missing note cannot create a blanket prompt. Unknown
   intended bytes defer/prepare comparison rather than manufacture a mismatch.
6. Resolve exact disclosed dependencies with existing bounded receive work and
   validate before association. No timeout makes missing history a new note.
   Preserve independent births when late history arrives after an eligible import.

Use attempt-local indexes of active paths and exact-byte digests when selecting
candidates, followed by the required exact checks. Build them from one coherent
current/transition capture and reuse them across that pass. This avoids a full
note/history walk for every file without adding a persistent identity registry.
Unknown encoded outputs stay explicit while bounded preparation supplies them.

**Tests / exit:** table-driven decision cases with independent expected reasons,
plus actual two-catalog/read races. Test candidate sets in differing orders,
multiple plausible notes, empty files, supplied metadata defaults, equal bytes at
two paths, absent xattrs, collisions, history/body/stamp permutations and a
mandatory exception matching the heuristic perfectly. Hold a provider read while
local saves complete. Stale frames publish no partial note/index/claim changes;
after finite interference ends, dirty work is processed without another event.
Storage/provider failures retain the existing bounded-attempt/recovery behavior;
the progress test does not authorize automatic failure polling or pretend that
unavailable I/O eventually succeeds.

## 8. P6.4 — Connect durable history to exact projection transitions

Capture output from the actual note generation and represented history, including
collision-adjusted leaf, encoding and mandatory metadata. Wait for its exact
local history barrier, then invoke P6.2 with fresh root/file checks. This is a
projection effect of existing history, not another note action.

Track intended and accepted generations separately. Serialize a note's physical
transition through source accounting, while unrelated local saving remains
independent. A verified/source-accounted B may advance accepted A→B while C
remains intended. It cannot clear C, reinstall an older model value or regress an
already accepted C. Retire A as a candidate only at the accepted-transition
boundary. Identical bodies with differing generations still require exact checks.

Commit the receipt/active-state change under existing required-private-state
transactions. On restart, interpret receipts as recorded observations, reconcile
with exact retained history and re-observe before effects. If receipt recording
fails after installation, the next pass must recognize/account for the effect
without losing displaced bytes or granting fresh cleanup permission. Keep source
obligations until completed or safely surfaced for reconciliation.

**Tests / exit:** initial creation; edits, labels, rename and format/encoding
changes; A→B→C with delayed completions at each barrier; external rename of A
while B is pending; B installed/source unresolved; C already settled; crash after
install before receipt; second failure during recovery; equal-body generation
changes; returned/new source occupant; metadata-only edits and missing optional
stamp. An external edit detected before replacement is preserved/reconciled
before proceeding; a race inside replacement retains the actual displaced
contents and reports reconciliation needed. Newer committed history alone
grants no overwrite permission.

## 9. P6.5 — Complete pending admission and association

### Automatic and explicit fresh import

Durably retain a verified pending snapshot before admitting work from it. Preserve
one latest preview and independent frozen admitted inputs using the existing
private tables. Commit replacement payload/reference atomically; failure leaves
the earlier readable snapshot. Absence or failed reads keep the last readable
preview, labeled as retained rather than current.

Reserve exact birth/action/operation identity before admission, under captured
item/model/relationship context. Ordinary automatic eligibility and explicit
Import as New share the captured-input path but retain their distinct reasons.
Admit through the ordinary action machinery, then recover exact committed
membership before settlement. A same body/name is not a duplicate-import key.
Changed preparation gets the protocol's new operation identity; ambiguous owned
sealed bytes retain their original exact identity.

### Association and explicit content choice

Represent **which note** and **which contents** independently. Validate a current
candidate and selection, then prepare one of:

- Equal complete values / Keep Current: neutral repair with existing Current's
  barrier and no new Put/action. If the selected file differs, Keep Current must
  safely project Current using P6.2–P6.4; the existing equal-value-only storage
  helper needs a properly scoped extension, not a bypass of its guard.
- Use the captured file values: ordinary supported mutation retaining exact
  before/after and the selected relationship/content context.
- Trustworthy-base reconciliation or explicitly reviewed merged values: use
  existing semantic preparation/reduction; preserve unselected heads. Without
  the required base/evidence, return for explicit review rather than fabricate it.

Publish the provisional relationship claim with the admitted model mutation and
pending history ownership. Recheck competing claims, new preview, root/view/note
generations and logical Delete at the actual admission consumer. A stale choice
cannot silently change its target or selected contents.

After the barrier and P6.4 physical verification, settle receipt and pending
references in one private transaction, using root-issued immutable evidence and
final collection-context checks. Newer preview remains separate work. A file
change between observation and commit requires subsequent inspection; settlement
never grants permission to overwrite that later occupant. On ambiguous private
commit, query exact identities before retry.

### Recovery and presentation independence

Process unresolved reservations against complete durable history before scanning
affected files for new imports. Exact committed operations still count when the
birth was later edited/deleted. Missing receipt means resume accounting, not new
Create. An uncommitted reservation returns to fresh classification/review; it
does not replay manual consent. Automatic re-admission requires fresh eligibility.

Closing presentation defers a decision; admitted work stays collection-owned.
Explicit abandonment releases only the specified unadmitted retained recovery
material, with the required disclosure, and neither deletes the file nor creates
a permanent ignore rule. Delete after admission cannot discard the exact
admitted operation: finish its captured history, deny stale final association
and retain any newer unreviewed input. Use existing repair/copy preservation for
all required pending records; damaged private evidence is not proof of newness.

**Tests / exit:** extend `PrivateStateTests.swift` through actual file consumers;
compare SQL payload/reference inventory as well as live notes. Cover competing
choices, neutral/changed cases, Keep Current over different bytes, multi-head
notes, automatic conflict adoption, preview replacement before/after admission,
Delete on both sides of admission, closure/dismissal, all ambiguous commit cuts,
and two crashes with a subsequent edited/deleted import. Unchanged repeated scans
or restart must not author another Import. Separate ordinary equal-content files
remain eligible for separate identities.

## 10. P6.6 — External edits, absence and lifecycle composition

For positively associated external changes, use the actual raw metadata and
captured note state. Preserve legitimate safe-save/handoff continuity under
qualified evidence, including stale or stripped advisory stamps; contradictory
provenance still takes the explicit path. Admit changed contents once through
ordinary history; self-generated body/stamp updates and receiving an existing
revision must not author echo actions.

For verified unexplained absence, return a headless decision governed by the
captured `confirmFileDeletion` preference, followed by final revalidation. Local
versus remote origin does not change trust. Restore before a logical Delete
keeps the birth; after Delete, explicit Restore uses the existing fresh-birth
semantics. A preference-disabled absence can be admitted automatically only while
the original absence remains justified. A plausible replacement's combined
repair decision suppresses a separate absence Delete even with confirmation off;
incoming committed Delete remains effective and invalidates stale association.

Originating NV Delete cleanup uses the exact original captured physical
operation after history durability. A received Delete or replayed checkpoint
never unlinks a matching-looking file. New occupants, user copies and stale
projections receive their specific reconciliation/restoration treatment.

Expose headless lifecycle/handoff inputs for later external-editor integration:
exact captured scratch contents survive until the corresponding generation is
durable; path reuse and scratch replacement require fresh checks. Do not launch
editors or change their UI in this increment. Encrypted-mode explicit scratch
export remains outside the provider folder and requires Phase 7's disclosure and
actual caller qualification.

**Tests / exit:** preference on/off and changes during review; local/peer absence;
file reappearance; coupled missing/repair choices; received Delete before/after
admission; Delete/remote edit with automatic preservation; Restore plus stale
backup; rename away/return; copied/stale stamp; external handoff completion after
note/root switch. Provider delay, full/unwritable projection and rejected optional
stamp must leave a healthy local save able to complete.

## 11. Critical scenario and observation matrix

All rows are **planned production witnesses**. Their existing component/model
coverage is supporting evidence, not a completed physical implementation test.
Use both private-store profiles where applicable; plaintext effects run only in
plaintext mode, with explicit encrypted-profile rejection/privacy companions.

| ID / contract | Schedule or challenge | Required independent result |
| --- | --- | --- |
| P6-C01 / TC-PROJ-01, TC-ROOT-01 | Change file/root/model between first catalog, read, second catalog and publication | No partial admission or absence inference; retained/admitted inputs survive; fresh observation resumes |
| P6-C02 / TC-PROJ-01 | Partial enumeration, placeholder, permission/read error, unknown encoding | Defer exact affected decision; no manufactured empty value/deletion/fresh import |
| P6-C03 / TC-IMPORT-01 | Healthy notes plus ordinary addition; unrelated missing note; one/multiple actual repair candidates | Expected automatic birth or individually justified review; no blanket prompt or pooled evidence |
| P6-C04 / TC-IMPORT-01 | Exact active path vs exact nonempty bytes; old accepted A, intended B; B settles | Only current permitted candidates, with A retired at settlement; fallback labels/dates create no evidence |
| P6-C05 / TC-PROJ-01 | All six body/stamp/history orders, then duplicate/reordered delivery | Wait/associate/import according to exact disclosed evidence; no echo action or timeout-derived newness |
| P6-C06 / TC-PROJ-01 | Malformed/foreign/copied/skewed/oversized stamp; duplicate descriptors/claimants | Preserve, omit safely or expose exact ambiguity; no alias, silent truncation or deletion |
| P6-C07 / TC-IMPORT-01 | Import before undisclosed peer birth/Delete, then edit both | Independent births and both edits survive; old Delete remains scoped to old birth |
| P6-C08 / TC-PROJ-02 | Latest A→B retention fails/commit callback lost; A already admitted | Raw SQL references retain the correct latest and independent admitted A; recovery uses actual commit result |
| P6-C09 / TC-PROJ-02 | Import committed, receipt missing, crash twice, import later edited/deleted | Same exact historical operation recovered; no new birth/action on rescan; newer preview retained |
| P6-C10 / TC-PROJ-02 | Two choices for one note, same-body new generation, new preview or root/view replacement | Actual consumer rejects stale choice; losing choice's input remains recoverable |
| P6-C11 / TC-PROJ-02 | Neutral repair, Keep Current with different file, changed/reviewed merge | Exact action counts and before/after values; no neutral Put or implicit preview overwrite/unselected-head consumption |
| P6-C12 / TC-PROJ-02 | Delete arrives immediately before admission, after admission, before final receipt | Stale consent blocked; admitted bytes become durable; stale association receipt withheld; any entered physical effect accounted for; newer input retained |
| P6-C13 / TC-PROJ-01–02 | A→B→C save/rename, delayed B receipt, same text across generations | Correct accepted and intended states; B never clears/regresses C; source accounting matches actual files |
| P6-C14 / TC-PROJ-01 | Concurrent replacement after preflight / during Foundation call | Exact displaced content retained and reported; actual installed output observed; clean success withheld on mismatch |
| P6-C15 / TC-PROJ-01 | Destination succeeds, source changes/returns or cleanup fails | New source occupant survives; incomplete transition remains accounted; restart grants no stale removal authority |
| P6-C16 / TC-PROJ-01 | Body/stamp/mandatory metadata failure at stage and readback | Unstamped verified success distinguished from uncertain install; mandatory errors not swallowed |
| P6-C17 / TC-PROJ-02 | Namespace effect succeeds, private receipt write fails repeatedly | Exact files/history remain; retry settles once after fresh checks, retaining old/new pending references as required |
| P6-C18 / TC-PROJ-01 | Absence with preference on/off; plausible repair; reappearance; incoming Delete | Expected review or exact logical Delete; combined repair prevents premature absence admission; no received-Delete sweep |
| P6-C19 / TC-PROJ-01 | NV Delete followed by same-name new file, stale backup and fresh-birth Restore | Only original still-matching authorized file may be removed; new/restored content survives |
| P6-C20 / TC-PROJ-02 | Dismiss before/after admission, explicit abandonment, file becomes unreadable | Latest retained recovery copy preserved as specified; no consent replay, unapproved import or lost admitted input |
| P6-C21 / TC-ROOT-01 | Held accessor, local save, root Retry/Re-open/switch/close, late completion | Local durable work progresses; exact old operation settles safely; current session remains unaffected |
| P6-C22 / TC-PROJ-02 | Private repair/copy with latest and frozen inputs, corrupt reservation or missing required evidence | Preservation inventory exact; explicit damaged/unsupported outcome rather than repeated fresh imports |
| P6-C23 / TC-PROJ-01 | History edit → local external edit → peer Delete → crash → Restore | Current/history/conflict contents and identities match independent expected policy, not just peer convergence |
| P6-C24 / TC-PROJ-01–02 | Two independent imports, third writer's logical edit/Delete, delayed receipts/history | No cross-birth collapse or lost content; bounded tested interleavings expose third-party effects |
| P6-C25 / TC-PROJ-01 | Marker-bearing values through success, failure, repair, scratch and encrypted-profile denial | Private pages encrypted; no unauthorized provider plaintext/title/stamp/temp/log channel |
| P6-C26 / TC-PROJ-01–02 | Growth, quiet scans, event bursts, finite interference then silence | Work counts meet declared bounds; no history-depth startup cost; unfinished work actually resumes without a new event |

## 12. How to qualify each increment

### 12.1 Independent observations and process schedules

Keep four observations separate: (1) actual file bytes/metadata/displaced artifacts,
(2) immutable envelopes and accepted membership, (3) raw private pending/receipt
references and current rows, and (4) headless live values, pending generations and
decision reasons. A successful API callback or two machines agreeing is not a
substitute for these checks.

Inject at reached boundaries: observation; latest-payload/reference commit;
reservation; provisional admission; history commit before callback; stage write
and synchronization; namespace effect; displaced-item verification/preservation;
source accounting; receipt/pending transaction; cleanup; and reopening. Cover
before effect, after effect/unknown completion and a second failure during
recovery. Hold callbacks/accessors using deterministic gates, not sleeps or a
fortunate task schedule. Observer controls must detect missing/altered data and
confirm the contested transition actually occurred.

Recovery children receive only surviving stores, files and normal selection/unlock
inputs. Keep expected notes, acknowledgments and desired outcome in the parent
observer. Record frozen wire/filesystem inputs, hashes, delivery/cut ordering and
seeds; replay exact identities as well as the same logical scenario. Distinguish
process termination, simulated persistence loss and later corruption. Physical
power loss remains a separate unperformed qualification unless actually executed.

Use bounded exhaustive schedules around two writers, one/two notes and two
failures; add selected three-writer histories for identity and overlap cases.
Do not multiply every schedule across every OS blindly: portable semantics run
in full, and native variants exercise each relevant capability and failure edge.
Every reduced platform selection records its coverage rationale.

### 12.2 Compile probes and targeted mutations

For each new issuer, require ordinary-client and same-module construction/field
mutation probes plus a valid companion. Reuse compatible compiler-probe batches,
but keep exact marked-line/rejection checks and individual fallback where batch
diagnostics hide a required rejection. Test same-type wrong-store/session/root/
view/item/relationship evidence at its real consumer. Preserve strict Swift 6.4
concurrency/memory settings, access control and audited C lifetime boundaries.

Add targeted defects, each caught at its intended observable assertion: skip the
second catalog/final context check; turn unavailable bytes into empty; bypass
provenance precedence; pool candidate evidence; normalize body matching; retire A
early; clear C on B completion; skip actual displaced verification; unlink by old
name; swallow mandatory metadata failure; release admitted input with latest;
replay an uncommitted reservation; find an import by live birth instead of exact
operation; split receipt/reference settlement; omit content choice; discard a
dirty request while active; and leak plaintext in encrypted mode. Reuse existing
relevant mutants before adding a duplicate. Keep the established mutation
cross-product unchanged, with nonzero discovery, passing companions and intended
failure attribution.

### 12.3 Model correspondence

| Existing model / runner selection | Phase 6 obligation and concrete gap to close |
| --- | --- |
| `ProjectionStampSafety` / `--only stamp-` | Independent body/stamp/history and unique association; real codecs, exact hashes and native xattr delivery remain executable checks |
| `ExternalFileLifecycleSafety` / `--only external-file-` | Latest/frozen/admitted ownership, repeat scan and dismissal; connect to real private transactions and caller admission |
| `PendingReferenceSafety` / `--only pending-reference-` | Reference replacement and cleanup across interruption; exercise actual SQL commit/ambiguity rather than assumed atomic storage |
| `ExternalAssociationSafety` / `--only association-` | Identity/content choice, competing claims and Delete; bind the model's choices to production preparation and physical settlement |
| `ProjectionTransitionSafety` / `--only projection-transition-` | Active A/B/C comparisons, exact generations and source accounting; native installation is a separate assumption |
| `ExternalRecoveryBridge` / `--only bridge-external-` | Pending input through causal history and peer Delete across repeated crashes |
| `ProjectionRecoveryBridge` / `--only bridge-projection-` | History, actual replacement/displaced retention, source cleanup, receipt and restart |
| `SeparateFileDeletionSafety` / `--only file-`; `CurrentVisibleReconciliationSafety` / `--only shared-catalog` | Original authorized removal and coherent publication; inspect the selected runner cases before execution because substring selectors may include additional families |

Use `docs/tla/check-segment-models.py` and the actual selectors in the TLA+ guide;
substring selection can include negative controls and witnesses. Retain existing
safety assertions and reachability companions. Update concrete correspondence
when an implementation splits a model transition. Extend/run only affected models
if that split introduces observable interleavings or changes an assumption; reuse
unchanged recorded finite results without presenting them as a proof of native
code. Keep fairness assumptions explicit and never make consent/network recovery
inevitable merely to obtain progress. No model rerun is required for this plan.
For each counterexample, distinguish an inaccurate abstraction from a genuine
specification/implementation defect using the concrete schedule and independent
observations. Repair the defect or seek a policy decision; do not remove the
schedule, weaken the assertion or return unsupported on an otherwise required
successful path just to qualify the feature.

### 12.4 Platform and API capability

Use the P5.7 platform ledger as the baseline, with new paths exercised on current
arm64 macOS, Intel macOS 14 and the available macOS 11 VM, plus arm64 Linux for
portable and actually supported native contracts. The macOS 11 test environment's
compiler/runtime workaround remains a packaging caveat, not blanket deployment
qualification. Linux must preserve the promised contract or return an explicit
unsupported capability; changing a check for compatibility needs approval.

Run production replacement and metadata tests on claimed APFS/HFS+/ExFAT and
case-sensitive variants as prescribed by the Foundation plan. Include moved and
deep roots, access permissions, read-only media and namespace adversaries.
Successful local disk tests do not establish provider scheduling or transport.

Extend the existing signed two-Mac harness for actual plaintext consumers:
ordinary creation/edit, stamp stripped/copied, safe-save replacement, rename,
delayed exact history, offline rejoin, remote deletion and retained pending
recovery. Use authorized synthetic subtrees, record source/binary/OS/filesystem
and both machines' exact observations. Deliver provider data through the provider;
SSH may control and inspect the test, not substitute for the claimed sync. Missing
stimulus/authorization/timeouts stay inconclusive. Reuse Apple probe results only
for the specific measured primitive; suspected contract violations require first
checking API use and interpretation.

### 12.5 Performance and resource gates

- Grow unrelated accepted history through 64, 256 and 1,024 actions with fixed
  current notes/files, and grow files separately with fixed history. Reuse closed
  shared-history seeds, cloning into independently owned mutable stores per case.
- Measure initial editable publication, reconciliation, local-save latency during
  a held scan, filesystem calls/bytes, SQL executions/rows, envelope decodes and
  peak retained memory separately. Healthy startup must use current rows and
  indexed required work, not read all separate files/previews/history first.
- Compare new complete catalog work to the legacy bulk scanner and P5 bounded
  metadata/hint results on equivalent metadata and filesystem fixtures. The two
  required catalog passes remain; remove duplicate per-item stat/SQL/decoding,
  not a safety fence. Changed bodies and exact evidence still require real reads.
- Repeated unchanged observations must avoid repeated imports/history decoding;
  narrow lookups scale with affected notes/references. Bound batches and yields;
  do not impose a lifetime history limit or silently drop dependencies.
- Burst hints coalesce. A save/event arriving while work is active remains visible
  at completion, following the P5.7 drain regression. Demonstrate eventual exact
  processing after finite interference stops without another file/hint/timer.
- Pending payload limits preserve old readable and admitted input on failure.
  Measure latest replacement with several frozen inputs; limits produce explicit
  outcomes rather than deleting recovery material to meet a memory target.

## 13. Qualification reuse, run entry points and deliverables

Reuse [build/result manifests](qualification-build-reuse.md), split test targets,
batched compiler probes and shared closed fixtures. Match actual source, native
dependencies, compiler flags, harness and artifact hashes for exact reuse. For
reviewed component reuse, list unchanged responsibility and invalidated consumers
separately; a prior passing full suite does not qualify a new physical path.

| Existing evidence | Reuse when unchanged | New work still required |
| --- | --- | --- |
| P2–P4 history/SQLCipher/current-row/private-state qualification | Unchanged commit, retention, pending-reference and recovery machinery | Extended codecs, physical settlement consumer and joined failures |
| P5.1–P5.4 roots, metadata batches, coordination and immutable transport | Same primitives, assumptions, source and platform scope | Complete plaintext catalogs and mutable-file effects |
| P5.5–P5.7 startup, repair/copy, receive/publication and source impact ledger | Unchanged admission, lifecycle and progress behavior | Projection/pending state through those actual consumers and new failure cuts |
| Legacy/native replacement tests and Apple experiments | Measured behavior and unchanged helper contracts | The new adapter, exact metadata/stamp variants and integrated callers |
| TLA+ results | Unchanged module/configuration and stated abstraction | New interleavings/assumptions, concrete correspondence and actual OS effects |

Use existing root-relative entry points, supplying real new test selections once
registered rather than documenting nonexistent commands:

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --no-parallel'
python3 tools/test-storage-phase2.py --configuration both
python3 tests/run-sqlite-schema-contract.py
python3 tools/test-storage-root-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-runtime-mutations.py --configuration debug --only <registered-name>
python3 docs/tla/check-segment-models.py --java "$TLC_JAVA" --jar "$TLC_JAR" --only <affected-family>
```

Register Phase 6 witnesses in the existing driver/target inventory as they land.
Targeted debug/optimized checks close each increment; reuse completed unaffected
full-suite results according to the manifest/impact rules. Run affected sanitizers
over new C/descriptor/staging/coordination cleanup boundaries, with valid and
deliberately invalid controls. Shared native caller changes additionally require
`make -C tests run-core`, `make -C tests run-platform`,
`bash tools/test-epoch4-v5-compatibility.sh` and `bash build.sh`; no unrelated
application rebuild is justified by this planning document alone.

Save incremental implementation/validation ledgers beside this plan (or under a
`phase6/` child directory), including:

1. Exact source/type/record contracts, invariant-to-issuer/consumer map and frozen
   fixtures; any approved deviations and model correspondence.
2. Each matrix row's actual test names, parameters, reached cuts, valid companion,
   independent observers, mutation and raw result locations.
3. Source/binary manifests, exact replay inputs, debug/optimized/platform and
   sanitizer results; failed attempts and corrected interpretations retained.
4. Performance work counts and timings; unavailable capabilities and remaining
   release/physical-power-loss gaps explicitly separated from completion.
5. Updated roadmap, `Format-TODO.md`, relevant annexes/ADRs/glossary where actual
   definitions change, and the [test/validation index](../../Test-and-Validation-Index.md).

**Phase 6 completion:** actual disk observations reach the adopted classifier;
every supported admission and physical effect consumes the proper evidence;
exact approved input and displaced contents survive the tested interruptions;
restart neither repeats admitted Imports nor replays stale physical permission;
newer pending work survives older completions; local editing remains independent
of provider delay. Phase 7 then implements the real user-facing callers with
human review. Headless completion does not claim that those UI workflows or all
release platforms have been qualified.
