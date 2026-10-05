# Phase 4C–4E: private state, verified repair and repository copy

Date: 2026-10-05. Status: portable local paths implemented; qualification and
remaining platform/provider limits are recorded in the
[4C–4E validation report](phase4-private-state-repair-copy-validation.md).

Implement **4C before 4D**: repair needs complete private-record codecs and
reference transactions before it can preserve those records in a replacement.
4E then reuses the verified-source, destination and activation boundaries.
Each increment closes through production-path tests before the next expands it.

This concretizes the remaining increments in the
[Phase 4 plan](phase4-startup-recovery-plan.md#subsequent-phase-4-increments) and
T05–T09 in the [data-safety contracts](phase4-data-safety-contracts.md). Its
authorities are the [specification](../../iCloud-Drive-Support-Spec.md),
[repair ADR](../../adr/0016-repair-from-validated-immutable-copies.md),
[canonical vocabulary](../../../CONTEXT.md),
[private-store mapping](../LocalStore.md#sqlite-backup-salvage-and-replacement-activation),
[pending-record protocol](../Protocol.md#pending-file-commit-and-recovery-records),
[Swift proposal](swift-storage-library-proposal-v2.md) and
[conformance strategy](swift-storage-conformance-testing-strategy.md).
Scenario IDs below organize implementation tests, not new product requirements.
The report maps those scenarios to actual production consumers and test functions.

## Outcomes and scope

| Event or requested operation | Storage responsibility | Later application surface |
| --- | --- | --- |
| Ordinary reopen | Recover current rows, required private groups and their exact outstanding work | Notes become editable through the existing publication checks |
| Damaged derived current rows | Rebuild from retained history while preserving settings and pending contents | Transparent recovery when the complete required state is available |
| Damaged private database | Preserve originals, collect complementary evidence, build and verify a fresh sibling, then durably select it | Transparent complete repair; precise recovery choices for genuinely incomplete state |
| Lost selection or unavailable unlocking evidence | Report re-association or credential requirements separately from history damage | Existing re-open/unlock/recovery flows |
| History-preserving collection copy | Preserve available exact repository history and associated files, with honest completeness reporting | Save Note Collection As… |
| Current-state recovery export | Capture complete current values into an explicitly fresh collection | A distinct recovery/export choice |

This increment supplies portable storage services and controlled local filesystem
qualification. Provider adapters and application UI remain in Phases 5–7; actual
external-file admission and installation remain Phase 6. The existing startup
Work Offline conditions and transparent same-root `NV Data` repair policy remain
unchanged. There is no Restore NV Data button to implement here.
4F's zstd current-cell integration and optional locality/maintenance work have
their [separate plan and gate](phase4-current-row-locality-maintenance-plan.md);
ordinary current-row startup stays the baseline.

## Starting point and implementation gaps

| Existing component | Reuse | Remaining work |
| --- | --- | --- |
| `LocalStoreSession` / `DatabaseLane` | Actor ownership, exact commit inputs, synchronous SQL transactions and publication fences | Complete private-group consumers and a controlled backup/repair lifecycle |
| `SchemaV1.sql` / `private_groups` | Scoped private values, generations, retained history and current rows | Pending payload/reference/reservation/receipt roles and complete nonempty settings |
| `Verification.swift` | Durable object/bootstrap/history verification requests and interrupted-diagnosis recovery | Preservation or proven settlement of these requests during repair |
| Accepted history and general snapshots | Exact immutable bytes, complete validation, all-branch reduction and derived-row rebuilding | Complementary-source reconstruction into a new store |
| `SelectedStoreRecordV1` / `RecoveryKeyV1` | Existing bounded codecs, checksum/typo fixtures and key derivations | Physical selection ownership, durable expected-generation activation and fresh-open qualification |
| SQLCipher backup/salvage probes | Evidence for the underlying API primitives and codec-error handling | Production readers, working copies, complete backups and repeated-failure tests |
| C directory owner | Rooted private access, nonblocking exclusion and identity checks | Controlled secondary readers, evidence-copy helpers and selection/candidate ownership |

The backup/salvage probes are prerequisites, not substitutes for testing the
actual runtime paths. Preserve epoch-4 opening/recovery and explicit legacy
export in the Mac application.

## Safety obligations and minimal state

1. **Preserve committed history.** Complete repair retains every known required
   object, action/dependency relationship and unpublished committed edit. Current
   rows alone cannot certify this. A missing required leaf prevents complete
   activation, even when its note's present value is available elsewhere.
2. **Preserve unique private inputs.** Latest preview B and admitted frozen input A
   can coexist. Settings, pending links and unfinished verification requests have
   durable ownership; rebuilding rows cannot discard them or manufacture consent.
3. **Verify a replacement before selecting it.** Its required closure, complete
   current state, private groups and ordinary unlocking route survive fresh open.
   Activation consumes that evidence under fresh physical/context checks.
4. **Preserve sources during uncertainty.** Interrupted backup, salvage, union,
   reopening or selection does not destroy the old database/journals, foreign
   occupants, admitted inputs or candidate evidence. Ambiguous cutover requires
   readback and preservation of both candidates.
5. **Recover by exact committed identities.** Missing callbacks or receipts do not
   create another Import. A previously committed Import remains committed after
   its birth is edited or deleted. Reservations return to review when no complete
   operation is found.
6. **Keep normal startup indexed.** Healthy reopening reads current rows and
   indexed required work. Backup and exceptional repair may visit all required
   history; their budgets yield and resume rather than discard dependencies.

Use the existing private groups, retained pin, verification records, selected
record and exact `unlock/` descriptors. Add dedicated pending roles when enabling
that feature, as required by the schema design; their reference graphs belong in
queryable records, not one opaque `private_groups` payload. Add only state needed
for an actual outstanding input, reference, selection or recovery obligation.
No per-edit sidecar, second journal or persistent general-purpose proof cache is
introduced. Old evidence and failed candidates remain preserved; automatic
cleanup is outside this milestone.

## Swift-enforced boundaries

| Boundary | Issuer / consumer contract |
| --- | --- |
| Private bytes → complete checked group | Bounded Core decoding yields claims; the owned validator checks scope, versions, links and generations before issuing an installable group |
| Health observation → decision | Immutable explicit outcomes describe scope, access and known damage; a health report is input to the repair decision, not replacement permission |
| Committed references → releasable payloads | Only the reference transaction's checked result supplies cleanup work; latest/frozen/history owners are examined independently |
| Captured source → complete backup | A controlled keyed reader owns one fixed read state and exact descriptor capture; completion follows destination verification |
| Repaired store → selected store | Fresh production reopening issues issuer-restricted `VerifiedReplacement` evidence; activation checks candidate, owner, selection and credential context |
| Copy versus export versus activation | Distinct commands/results express available-byte preservation, complete private recovery and fresh-current-state export; switching is a separately checked effect |

Keep constructors `private` or `fileprivate` with their validator/committer.
Ordinary-client and same-module sibling probes challenge initializers, setters,
decoding and convenience factories. A decoded selection record remains a claim.
Tests must also deliver correctly typed evidence for the wrong store, candidate,
association, selection generation or key/profile to the actual consumer.

Retain actor isolation for mutable connections, statements and lifecycle state.
Database transactions remain synchronous. Workers receive immutable checked
`Sendable` inputs; they reserve ownership before suspension and recheck context
when consuming a result. Each secondary connection has one explicit owner on a
blocking-I/O execution resource. Borrowing the primary directory owner preserves
its lifetime and lock; it cannot release the primary's ownership. Use selective
noncopyable handles only where they simplify resource transfer and cleanup.

## 4C — Required private state and common health outcomes

### C0. Inventory, layouts and independent fixtures

- Inventory `NotationPrefs`, relevant `GlobalPrefs`, remembered cursor ranges and
  existing association fields. Map each to collection-private settings,
  application-global settings, platform-adapter data or legacy-only import data.
  Define supported nonempty settings rather than expanding the existing empty
  codec into an unrestricted archived dictionary.
- Keep platform font/color/bookmark representations passive, bounded and
  versioned at the adapter boundary. Portable Core validates their framing;
  platform interpretation remains with the host. This does not expand the
  deferred rich-note formats or add attachments.
- Freeze association/settings and pending snapshot/item/reservation/settlement
  fields from Protocol: exact observed metadata/presence separately from decoding
  defaults, item generation, latest/frozen references, captured scope, operation
  identity, represented-state references and remaining subsequent-file work.
  Keep large values in referenced payloads/history and distinguish neutral repair
  from a content-changing operation.
- Specify required table roles, indexes, foreign-key/reference rules and complete
  group boundaries. Keep independent scalar/golden fixtures and schema checks
  synchronized with Core and Runtime. Existing incomplete/incompatible stores
  receive explicit outcomes rather than initialization over their contents.

**Gate:** independently generated positive bytes, malformed/unsupported/truncated
cases and SQL constraints distinguish complete groups from quarantined fragments.
Freeze layouts and precise outcomes before allowing production writes.

### C1. Complete private-group installation

Implement bounded codecs and generation-checked transactions for supported
association/settings groups and pending roles. Validate all applicable references
before installation. Preserve unsupported/private fragments as evidence and
report their actual scope. A private pending-item failure parks that item; required
central private-state failure follows the existing edit/repair gate.

Rebuilding derived rows preserves supported nonempty settings and pending data.
Settings replacement changes only its captured group; it cannot regress the
retained history pin or overwrite a newer group generation. Required work has
indexes for lookup and iteration; large preview bodies are loaded when needed.

### C2. Pending reference and restart transactions

Implement the storage portion of the pending protocol through a headless harness:

1. Safely retain snapshot A and its latest reference in one transaction. A later
   validated B replaces latest atomically; frozen A remains independently owned.
   Before/ambiguous completion keeps the previous durable reference and exact
   in-flight bytes until actual committed generations are queried.
2. Reserve birth/action/operation identities and exact inputs before admission.
   Model publication and physical association remain later-phase consumers; the
   harness supplies explicit accepted/rejected applicability outcomes at that
   boundary. Reservations preserve retry identity, not replayable manual approval.
3. Match complete accepted operation/action/dependency evidence before recording
   completion. A neutral repair instead checks its represented Current closure;
   it authors no echo Put. Commit receipt/settlement and pending-reference transfer
   together after the controlled physical consumer has supplied fresh evidence.
4. Release only inputs whose values and still-required links have another durable
   owner or were explicitly settled under the adopted decision. Cleanup failure
   retains extra bytes. A newer unreviewed B is independent of settling admitted A.

On reopening, recover history and reconcile affected pending links **before**
fresh-import classification. Lost receipt/callback resumes association using the
same committed operation, including after a later edit/Delete. An uncommitted
reservation returns to undecided/revalidation work. Contradictory/partial evidence
parks the affected recovery rather than allocating repeatedly. Historical receipt
data requires re-observation before physical effects.

**Gate:** latest B / frozen A, neutral association, committed Import with lost
receipt, same-birth later Delete, repeated crashes and cleanup/storage failure
all retain the correct contents and exact retry identity. These tests qualify
private storage, not Apple file installation or application user consent.

### C3. Compositional diagnosis through real opening paths

Implement the shared immutable health result described by Protocol: scope,
entry kind/access, known damage and required closure, validated complementary
candidates, and positive withheld-provider evidence. Start with private storage
and controlled local repository inputs. Real provider evidence is added in Phase 5.

Distinguish missing/wrong-kind/symlink/inaccessible entries; wrong or unknown
credentials/profile; unsupported formats; malformed required private groups;
invalid derived rows; accepted-history damage; and unique pending-content loss.
Raw `SQLITE_NOTADB`, permission or provider errors alone cannot decide those
categories. Preserve the underlying cause and recoverable bytes.

Connect classification to production consumers: ordinary open, derived rebuild,
admission refusal and repair preparation. Preserve existing verification reminders
and the history-damage latch. Required corruption remains known until positively
verified/repaired, including failure while recording a diagnosis. A rejected
received object remains isolated from accepted history; it is not grounds for
discarding the collection.

**4C exit:** C0–C3 pass both profiles with nonempty settings/private inputs,
indexed restart processing, exact failure classification and construction/consumer
probes. Physical external-file policy and UI remain later gates.

## 4D — Backup, complementary repair and verified activation

### D0. Narrow physical ownership and I/O primitives

Extend the existing rooted C boundary with controlled secondary keyed readers,
preserved working-copy creation and selection/candidate ownership. Freeze and
qualify lock acquisition/handoff for an already-owned active store and a fresh
candidate. Independent contenders must fail explicitly without blocking each
other indefinitely or releasing another connection's lease.

Implement expected-generation selection installation with positive owner/entry
checks, exact readback and file/directory durability barriers. macOS follows the
[safe-replacement caller contract](../../Foundation-Safe-Replacement-Migration.md#caller-scope-under-proposal-5)
and [Apple contract evidence](../../Apple-API-Contract-Validation.md). Portable
implementations preserve the same authority and failure obligations; platform
limitations are reported, not silently weakened. An unrelated replacement is a
conflict to preserve, not permission to overwrite. Foundation replacement is not
a compare-and-swap against an uncooperative writer.

### D1. Consistent complete private backup

Briefly fence association/descriptor transitions and establish a fixed read
transaction on a separate keyed connection under the existing physical owner.
Capture collection/store/key/profile, acceptance prefix, required pin/private
groups and exact applicable unlocking descriptors. Release that fence before
bulk backup so ordinary saves continue.

Use bounded SQLite backup steps into an owned, correctly keyed destination.
Limit the reader/WAL retention cost; cancellation or budget expiry settles the
reader and returns an honest incomplete/retryable result. It cannot indefinitely
hold a local-write fence. Test live-WAL contents explicitly.

Install exact descriptors and sync/close the destination, then freshly reopen
with ordinary selection/unlock inputs. Check the captured history/pin, settings,
latest/frozen pending links and verification requests. Newer source writes are
outside this captured backup. The database backup preserves its source header
identity; conversion into a newly activated local-store identity belongs to D3,
not an opportunistic header rewrite.

Compare the raw copied tables and view metadata before a normal opener can advance
captured ready work or rebuild derived rows. Then audit the recovered result
separately. This keeps exact-copy evidence distinct from logical recovery while
excluding source writes after capture. The backup's source prefix and its reopened
store's later accepted prefix have separate meanings.

### D2. Preserve originals and salvage a working copy

Suspend new admission while preserving live/admitted buffers. Quiesce connections
and preserve the original database plus required journals as one evidence set.
Unreadable originals remain untouched. Journal recovery and salvage operate on a
complete working copy; originals retain their recoverable state.

Use normal journal-recovered SQL reads for v1 salvage. After a page/codec error,
open a fresh keyed working-copy connection before independent known-identity or
range reads. One failed scan does not establish that every row is lost. Validate
exact object/descriptor bytes and complete private groups independently.

Keep committed provenance distinct from byte validity. Valid orphan objects and
low-level recovery remnants do not prove that a local user action committed.
Quarantine ambiguous fragments and preserve their bytes; a normally recovered
committed copy or independently matched committed evidence supplies the positive
companion. Parked/rejected receive inputs retain their bytes and classification
separately from accepted history.

### D3. Build and verify the complementary union

Create a fresh sibling `localStoreID`. Reconcile validated working-copy,
repository and backup inputs by exact identities and complete dependencies.
Preserve exact sealed bytes and action relationships while rebuilding local
acceptance/current indexes through the normal validators. Allocate fresh local
batch/view identifiers and retain all branches needed for history, conflict and
Undo/Redo behavior.

Check the surviving required pin and every known unique committed/unpublished
object and required private input. Restore complete settings/pending reference
groups; preserve their source scope as historical evidence and establish the new
store's binding explicitly. Partial groups remain preserved but incomplete. A
gap cannot become a complete repair because current note values look right.
After total private-state loss, available repository recovery establishes a fresh
association; it cannot claim discovery of history or pending bytes whose every
record was erased.

Handle verification requests explicitly. Object/bootstrap requests retain exact
identity and context. A history request for source prefix H describes that
source's accepted membership: the candidate's numerical H may identify a
different set. Preserve or rebind only through verified exact scope coverage;
successful checking of the full source obligation may settle it. Failure to
establish that coverage remains an incomplete repair. Merely copying the old
number or deleting the request is not settlement.

Commit the candidate's association, required pin and validated private records
transactionally. Freshly reopen it with normal credentials, perform indexed
required work and check complete current values plus continuation/history
queries. The old damage latch is settled only by actual verified repair; physical
receipts/reservations remain historical inputs for fresh re-observation.

### D4. Select only a verified reopenable candidate

Issue restricted replacement evidence after D3's durable candidate and fresh
open succeed. The activation consumer rechecks exclusive ownership of selection
and both stores, expected selection generation, candidate identity and credential
context. Durably install the existing selected-record format, read back exact
bytes and acknowledge only after its required barriers. Allocate fresh writer
epochs/action origins; uncertain old commits retain their exact identities.

Before activation the selected source remains the restart choice; after durable
activation the verified candidate does. Failure during replacement/synchronizing
can leave an ambiguous selection outcome: retain both stores, read the actual
reference and reconcile it. Tests allow only the permitted old/new outcomes for
their fault class; they cannot require the old record after an ambiguous write
that actually installed the new one. A foreign occupant is preserved and refused.

**4D exit:** the actual backup, working-copy salvage, union and selection paths
pass fresh-process, repeated recovery-failure, credential and owner/context tests.
Missing required history/private contents prevent complete activation. No old
source is deleted. Device credential provisioning, real provider repair and
physical power-loss qualification keep their separate stated limits.

## 4E — Reuse for collection copy and recovery export

Implement the [copy/export contract](../Implementation.md#repository-copy-versus-current-notes-export)
after D's verified-source/destination primitives are available.

1. **Repository-only copy:** capture available repository entries and preserve
   their exact bytes, descriptors and associated/unknown files without source
   Application Support. Locked ciphertext can be preserved. Report unreadable or
   changed captured entries and incomplete known dependencies separately from
   successful byte preservation. The result does not claim undisclosed remote
   history or complete private recovery.
2. **Active-session recovery Save As:** when recovering from missing/incomplete
   `NV Data`, drain admitted work through the existing barrier,
   incorporate locally saved unpublished history through the repair union, and
   state the copy's actual scope. Pending-file recovery buffers stay usable at
   the source and their exclusion is disclosed; copying the repository cannot
   silently count as backing them up. A failed barrier preserves its owned work
   and offers only the existing honest alternatives.
3. **Current-state recovery export:** capture coherent complete current values
   into a fresh collection under the adopted export policy. Keep its fresh
   identity/history promise distinct from history-preserving copy. This is the
   explicit path for available unsaved values when complete history recovery is
   unavailable.
4. **Optional switch:** copying alone leaves the active collection unchanged.
   Retain/settle admitted source work before switching, independently of a
   repository-only copy's completion.
   Switching additionally verifies destination credentials, association and
   durable selection. Preserve sources throughout. Positive destination/root
   authority and credential effects are completed by later platform adapters.

**4E exit:** distinct copy/export results pass repository-only, locked input,
concurrent-change, missing-dependency, pending-RAM/private-buffer and interrupted
destination/switch tests. Controlled local tests qualify storage obligations;
actual placeholders and application choices remain Phases 5/7.

## Risk-ranked executable matrix

Run every applicable case for PublicSegmentsV1 and EncryptedSegmentsV1. Each row
needs a valid companion, a named assertion proving the difficult transition was
reached, and independent observations beyond the runtime's success flag. A
fixture that returns unsupported or avoids the contested transaction cannot
qualify that feature. Prioritize PC01–PC04 and RP01–RP10 before optional work.

| ID / boundary | Schedule or fault | Independent observation / mutation to catch |
| --- | --- | --- |
| PC01 / private preservation | Nonempty settings, latest B and frozen A; damage derived rows and rebuild/reopen | Exact settings, payloads and references survive with correct current notes. Catch settings reset or treating pending BLOBs as cache. |
| PC02 / latest/frozen switch | Crash/fail before and after payload/reference commit; hold callback, install newer generation, then release it | Old or new committed reference has its complete payload; frozen A survives. Catch early release, mixed payload/reference commit or stale completion. |
| PC03 / exact Import recovery | Import commits, receipt does not; edit or Delete its birth, crash twice, scan the same observation again | One exact Import/action/birth in retained history; settlement does not revive the deleted birth. New preview B remains independent. Catch live-note-only lookup or reallocation on restart. |
| PC04 / reservation and neutral repair | Restart an uncommitted manual reservation; separately crash neutral repair before/after receipt | Fresh applicability/review is required; the valid neutral companion authors zero Put/actions. Catch replayed consent, echo Put or speculative completion. |
| PC05 / private-group generations | Older settings/pending completion arrives after newer history or private generation | Only matching captured group changes; history pin and newer private state remain intact. Catch stale generation acceptance or pin regression. |
| PC06 / complete codecs and groups | Truncation, unsupported version, wrong scope, oversized fields, missing/contradictory links and fragment salvage | Precise scoped outcome; original bytes survive; complete positive group remains usable. Catch defaulting away required state, incomplete installation or unchecked allocation. |
| PC07 / health consumers | Missing, wrong-kind, symlink, permission, wrong key/profile and unsupported-format fixtures | Actual open/repair gate distinguishes these from derived damage and accepted-history loss. Catch error-code-as-absence or automatic empty-store creation. |
| PC08 / isolated versus required failure | Targeted pending-retention EIO/ENOSPC while unrelated commits can succeed; separately make required database commits fail | Pending-only failure parks that item while unrelated save works; failed required commits preserve admitted work under the durability gate. Catch blanket blocking or premature success. |
| RP01 / fixed-state backup | Noncheckpointed WAL, nonempty private state; continue writing after capture and change descriptor/settings later | Fresh child sees exactly captured durable history, private groups and usable descriptors, not a mixed cut. Catch main-file-only copying or mutable-reader backup. |
| RP02 / unlocking | Public copy without Keychain/sidecar; encrypted copy with retained wrappers plus secret; wrong/missing credentials and profile companion | Ordinary fresh opener verifies header/bootstrap and full required state. Catch key-setting success as verification, missing wrappers or encrypted downgrade. |
| RP03 / backup resources | Cancellation, long reader/WAL budget, busy, EIO/ENOSPC, close/reopen failure | Incomplete backup is explicit; reader/fence settles, source saves progress and retry succeeds. Catch leaked reader, held write fence or early complete result. |
| RP04 / actual salvage | Corrupt encrypted pages with healthy committed objects/private groups elsewhere; fail a scan, then independent reads | Fresh working-copy connections recover intact independently expected data; original database/journals remain preserved. Catch sticky-error reuse, one-scan total-loss inference or repair in place. |
| RP05 / committed provenance | Valid orphan bytes, low-level remnants, parked/rejected candidates, plus known committed companions | Ambiguous inputs remain quarantined; only validated committed history becomes accepted. Catch valid-bytes-as-user-command or blindly restored acceptance flags. |
| RP06 / complementary union | Source G+L and peer G+R, unique unpublished object/private payload, duplicate packages; fail pin/private commit and recover again | Exact required union and all branches survive; absent L/private payload blocks complete activation. Catch current-only repair, dropped duplicate-byte coverage or incomplete pin. |
| RP07 / verification scopes | Outstanding object/bootstrap/history requests; change candidate acceptance order; fail verification or diagnosis again | Every source obligation is proven covered, preserved or explicitly incomplete. Catch copying old H as target H, dropping reminders or clearing damage on candidate creation. |
| RP08 / evidence consumers | Well-typed replacement evidence for wrong store/session/association/generation/profile/descriptor set | Actual activation refuses it; matching companion activates. Catch omitted context check or evidence fabricated outside issuer. |
| RP09 / physical exclusion | Independent contenders, selection-parent replacement, symlink/foreign occupant and lost directory identity | No concurrent owner or foreign overwrite; captured path/ID does not reacquire authority. Catch lock handoff error, borrowed-owner release or pathname-only activation. |
| RP10 / cutover and repeated failure | Crash before/after candidate close, fresh reopen, selection install, file/directory sync and readback; fail the next recovery too | Normal restart selects only the permitted complete store or explicit repair outcome; both evidence sets survive uncertainty. Catch early activation/acknowledgment or deleting the old candidate. |
| RP11 / total-loss limits | Erase selection/private pin versus retain a pin with a missing required object | Fresh association reports available recovery without invented erased history; known missing requirement blocks complete success. Catch newest-name selection or fictitious completeness. |
| RP12 / connected history semantics | Two/three writers: edit, Delete, preservation, Restore, reciprocal conflict copies and Undo/Redo; then repair/reopen | Independent expected identities, history entries, dispositions, recently-deleted state and compensation candidates, not just equal Current. Catch branch flattening or omission of action relationships. |
| CP01 / repository-only copy | Available/locked repository and unknown files, with complete or missing dependencies | Exact captured bytes preserved; completeness and unlocking are reported independently. Catch an undisclosed private-source prerequisite or current-row substitution. |
| CP02 / changing copy source | Captured entry changes/disappears, permission failure, interrupted destination | Honest partial/retryable result and preserved source/foreign entries. Catch silent omission or claiming uncaptured new history. |
| CP03 / active recovery copy and export | Unpublished saved work, admitted RAM work, pending preview; fail drain/copy, then use explicit export | Claimed saved history is actually present; unsaved values and private buffers retain ownership or the explicit export guarantee. Catch repository copy presented as complete private backup. |
| CP04 / optional switching | Successful copy but wrong destination credentials, stale association or failed cutover | Active source remains selected unless separately verified switching succeeds; source data survives all outcomes. Catch copy completion implicitly switching collections. |

Add connected schedules, not just component tests:

- Distinguish an item-scoped retention failure from whole-store unwritability.
  PC08 does not promise successful note saves while the database itself cannot
  commit; that case follows the ordinary local-durability failure gate.
- Latest B while frozen A's Import commits → logical Delete → lost receipt →
  working-copy salvage → complementary repair → ambiguous selection → another
  recovery failure. Observe A in exact history, B still retained, no duplicate
  Import and no old-birth resurrection.
- Fixed-state backup while another writer's history arrives and a new local edit
  is admitted. The backup covers its precise captured cut; repair includes every
  subsequently known required committed branch. Owned uncommitted input remains
  available rather than being silently attributed to the backup.

## Execution, oracles and scaling

### Fixtures and observation

- Follow the conformance strategy's valid companions, named discovery/assertion
  checks and isolated mutations. Reuse `test-storage-phase2.py`, compiler-boundary
  drivers, schema checks and the existing process/mutation infrastructure. Add
  a focused private-state/repair driver as needed; freeze its commands/filters
  only when the tests exist. Every qualification invocation requires nonzero
  discovery of its intended cases.
- Swift Testing parameterizes profiles and fault cuts with fresh owned directories.
  Use existing named gates and awaited tasks to control concurrency. Serialize
  only suites sharing a process-global test hook; prefer per-owner hooks.
- Generate private-record/selection/descriptor fixtures independently of the Swift
  encoder. Inspect actual envelopes, SQL membership, private payload/reference
  identities and selected-record bytes using independent tools. Success flags,
  note count or two stores agreeing are insufficient recovery oracles.
- A fresh child receives only surviving storage, normal selection/unlock inputs
  and its requested operation. Expected contents and acknowledgment traces stay
  with the parent/oracle; they are not recovery inputs. Contender processes test
  real exclusion rather than an in-process lock simulation.

### Distinct fault classes and mutation controls

Keep process termination, test-VFS simulated persistence loss and later corruption
separate. Cut every relevant transaction/barrier before, after and after success
but before notification. Repeat failure during reopening/repair and while recording
diagnosed damage. Record the precise survival guarantees of each fault class;
process-kill success does not qualify physical power loss.

Add isolated mutations for early payload release, replayed reservation, duplicate
Import, pin regression, omitted private/unpublished union member, dropped
verification scope, stale evidence, skipped fresh unlock, premature selection
acknowledgment and foreign overwrite. Require the intended assertion to fail;
timeout, missing discovery, compiler error or unsupported outcome is not a
successful mutation challenge. Pair construction failures with actual
same-type/wrong-context consumer tests.

Run debug and optimized suites, strict Swift concurrency/memory-safety diagnostics,
static ordinary/same-module clients, independent byte/schema checks and affected
mutations. Audit new C lifetime/cleanup branches under ASan and applicable TSan
with the intended SQLCipher build instrumented. Keep exact platform failures
visible; Linux compatibility does not lower ownership or durability contracts.
Repeat affected macOS/Ubuntu checks when available and record unavailable
deployment/platform and physical power-loss qualification explicitly.

### History growth and work budgets

Measure fixed current-note/private-active sets with increasing unrelated history,
including the first ordinary save after reopen. C's required processing uses
indexes and loads only outstanding groups/payloads. Adding private state must not
turn healthy launch into a scan of every historical object or preview body.

For large backup/repair, record object reads/decodes, SQL work, peak memory,
reader/WAL retention and local-save waiting time. Reuse at-most-once traversal
decoding and bounded workers. Require progress after finite interference ends
without another incoming file; cancellation/retry retains exact inputs.
Keep private-group and decode ceilings distinct from resumable collection-wide
work: history remains unbounded, not truncated to a per-pass budget.

## Model correspondence and qualification limits

Check the models through [their README](../../tla/README.md), effective
configurations and runners, rather than their names alone:

- `RepositoryRepairSafety` covers complementary union, required coverage and
  fenced effects. Its finite abstract health/source values do not qualify actual
  credentials, private codecs, SQLite salvage or selected-record I/O.
- `ExternalRecoveryBridge` and the pending/reference models supply latest/frozen,
  exact import-recovery and stale-association obligations. SQL transactions map
  these ownership transitions to this implementation; obsolete private file/WAL
  installation machinery is not restored.
- `VerificationRecoverySafety`, the SQLite/history models and reconstruction
  checks supply interrupted-diagnosis, atomic acceptance and complete-history
  recovery obligations. D3 still needs real tests for source-to-target scope
  mapping and independently surviving unique private data.

Add a small focused repair/activation model if implementation splits a transition
that existing coverage treats atomically. Start with two complementary sources,
one latest/frozen pair, a committed/uncommitted Import, a source verification
scope and old/new selection candidates; bound schedules to one or two failures.
Assert preservation and no early activation independently of successful results.
Add witnesses and targeted mutants, then fair progress after finite interference.
State-space bounds are test abstractions, not runtime retention limits.

This document changes no modeled behavior and requires no TLC rebuild by itself.
When implementing a behavioral change or adding a model, update correspondence
and run the applicable positive, witness and negative-control configurations.
A valid counterexample prompts a spec/implementation review; assertions are not
weakened merely to obtain a pass.

## Deliverables and completion order

| Increment | Required deliverables / completion gate |
| --- | --- |
| C0 | Private-field inventory, exact layouts/limits, dedicated pending DDL and independent fixtures |
| C1–C3 | Production codecs/reference transactions, restart lookup, shared health consumers; PC matrix and type/mutation checks |
| D0–D1 | Qualified physical/reader ownership and complete fixed-state backup; RP01–RP03/RP08–RP09 companions |
| D2–D3 | Preserved working-copy salvage, complete complementary union and source verification-scope handling; RP04–RP07/RP11–RP12 |
| D4 | Fresh-open evidence and durable selection; RP08–RP10, repeated failures and connected schedules |
| E | Distinct history-copy/current-export/optional-switch paths; CP matrix through controlled portable adapters |

Keep a validation report alongside this plan with each scenario **planned,
implemented, executed, failed or unqualified**, commands, source/dependency
revisions, independent observations, discovered defects and mutation results.
Update Format-TODO only when its layouts or qualified paths actually complete.
Record later-provider/UI and physical-power-loss limits without claiming those
phases finished. These increments require no new product-policy choice; any
newly discovered policy contradiction is brought to the user before changing it.
