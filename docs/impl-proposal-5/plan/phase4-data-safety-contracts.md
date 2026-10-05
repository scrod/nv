# Phase 4: data-loss tests and Swift contract boundaries

Date: 2026-10-02. Status: planned production tests and implementation boundaries.
This expands the [Phase 4 plan](phase4-startup-recovery-plan.md), using the
[conformance strategy](swift-storage-conformance-testing-strategy.md#3-test-the-obligations-not-just-their-names)
and [Swift library proposal](swift-storage-library-proposal-v2.md). Scenario IDs
below identify planned tests, not additional normative requirements. Proposed
type names illustrate responsibilities; freeze their actual signatures with the
corresponding increment.

The [4C–4E private-state, repair and copy plan](phase4-private-state-repair-copy-plan.md)
concretizes T05–T09's remaining private-state and physical recovery gates. Its
PC/RP/CP matrix covers retained inputs, complete backup/union, verification-scope
mapping and selected-store cutover with fresh-process, I/O and compiler-boundary
checks. These new scenarios remain planned until their production paths execute.

The [first Phase 4A report](phase4-general-snapshot-validation.md) records executed
byte, assembly and accepted-history-cut checks. These are components of the
scenarios below; snapshot installation, fresh-process snapshot-tail recovery and
physical repair keep their separate later qualification gates.

The next [received-snapshot S2 plan](phase4-received-snapshot-plan.md) concretizes
T03/T10 and the retention/verification portions of T01/T02/T05. Its RS01–RS12
matrix carries the observed index, connection, lifecycle and scaling concerns
into production-path tests; T01/T02's actual snapshot-based reconstruction still
requires S4.

## Prioritize irreversible losses

The first four risks concern losing history or the ability to recover it. Test
them before performance, optional maintenance or live-provider adapters.

| Priority | Failure to prevent | First qualifying scenarios |
| --- | --- | --- |
| P0 | A snapshot or rebuilt view silently drops a committed edit, Delete, conflict alternative or action relationship | T01–T04 |
| P0 | Recovery treats lost required history as disposable current-row damage and publishes stale editable data | T05 |
| P0 | Backup/repair loses unique unpublished history, a pending input or the only usable unlocking route | T06–T08 |
| P0 | Selection cutover abandons the old store before its replacement is complete, durable and reopenable | T09 |
| P1 | Duplicate deliveries, blocked dependencies, cancellation or finite editing interference prevent complete recovery | T03, T10 |
| P1 | Optional compression or maintenance regresses correctness or impedes required saves | T11 |

An acknowledged action must survive **in history**, together with its complete
group and dependencies. Later valid actions can change Current. Already admitted
but unacknowledged inputs retain the existing ownership/retry obligations; typing
that has not reached admission has no newly invented crash guarantee. Keep these
three assertions separate when constructing each oracle.
Complete values, safe format bounds and source preservation apply at every gate,
including optional work; lower scheduling priority never weakens their safeguards.

## Separate concerns at their actual trust boundaries

Reuse the existing targets and acceptance machinery. Add a type when the caller
could otherwise confuse materially different facts, and require a concrete
consumer test for that distinction. Most immutable records/evidence remain
ordinary copyable `Sendable` values. No additional persistent proof cache,
per-edit sidecar or universal `Segment<State>` hierarchy is needed.

| Boundary | Issuer and output | Consumer obligation / strongest practical Swift restriction |
| --- | --- | --- |
| Envelope and page parsing → complete preview | Core decoders check selected collection/profile, bounded framing, exact locators, manifest and page completeness; issue a complete protected preview | Preview consumers receive full checked displayed values. A distinct parameter type separates preview from a history-verified recovery basis. Public-profile checksums and encrypted-profile authentication retain their different guarantees. |
| Snapshot claim → verified state at a stated history cut | Semantic verifier establishes complete action/dependency closure and compares claimed values and continuation indexes with actual history; issue a `VerifiedSnapshotBasis` | Private/file-private construction binds exact root/page identities, represented operation frontier and verifier version. Decoding yields claims; calling the verifier establishes evidence. Installation additionally checks store/session and applicability. |
| Verified exact bytes → accepted durable history | Runtime combines verified bytes and complete membership using the existing private `ValidatedHistoryBatch` boundary | Only the owned synchronous acceptance transaction issues its receipt after bytes, membership, required descriptors, pin and wakeups commit together. Keep object dependencies and operation/action frontiers nominally distinct. |
| Accepted history → rebuilt rows → publication | Worker prepares immutable rows/context for an explicit accepted target and starting view; actor installs under a guard, then existing `PreparedModelChange` fences publication | Separate preparation from installation. Final consumers check actual physical ownership, store/session, accepted target, view/presentation epoch and host generation as applicable. Constructors bind evidence; these runtime checks establish that it still applies. |
| Private pending records → settled/releasable inputs | Private-state updater validates complete groups, links and expected generations, then commits reference replacement or settlement | Explicit variants carry latest, frozen and completed-operation references. Cleanup consumes the committed reference state; it releases only payloads with no remaining owner. An operation reservation represents retry identity, not user consent. |
| Captured backup → verified repair candidate → active selection | Backup freezes a consistent read state; repair independently validates the candidate union; a fresh production opener issues a `VerifiedReplacement` | A selected-store activation method accepts verified replacement evidence rather than a pathname, decoded selection record or open SQL handle. Recheck both owners, expected selection generation and credential/descriptor context at actual cutover. |
| Available repository bytes → complete private recovery / repository copy / current-state export | Separate commands issue results describing what was actually preserved and verified | Use distinct result variants and exhaustive internal switches. Complete recovery requires closure and required private groups; available-byte copy and explicitly disclosed current-state export carry different promises. |

Place issuer-restricted constructors with the implementing validator/owner.
`internal` alone permits construction from sibling files. Check setters,
memberwise initializers, decoding conformances and convenience factories as well
as explicit initializers. Clients may request validation; they cannot declare
that it succeeded. A checksum-valid `SelectedStoreRecordV1` remains a decoded
selection claim; positive physical ownership and verified activation are separate
facts. Likewise, `RetainedGraph` remains input to the relevant checks rather than
automatically becoming snapshot-verification evidence.

Keep immutable facts and revocable permissions distinct. A verified snapshot at
an old cut can remain valid after another save. Installing it as the whole current
view requires accounting for the accepted work outside that cut. A copied fact
does not reacquire a lost directory lock, authorize a different store or supply
fresh user approval.

### Actors, synchronous transactions and bounded workers

Keep `DatabaseLane` as owner of the connection and SQL state, on its existing
blocking-I/O executor. Its synchronous transaction closures prevent suspension
inside acceptance, private reference replacement and row installation. Core
verification operates on immutable inputs; bounded workers release database
access between reads. Each connection used for backup also needs one explicit
owner and controlled lifetime.

Checked `Sendable` inputs/results and `@Sendable` worker closures constrain
cross-owner transfer. The mutable connection/statement wrappers remain isolated;
workers receive bounded owned bytes and identifiers. Where a borrowed SQL-column
view would help, qualify its lifetime through statement reset/finalization and
the C boundary before adopting it. Retaining owned bytes is the correctness
baseline. Strict memory-safety diagnostics identify explicit unsafe operations;
FFI lifetime, bounds and cleanup still need review and sanitizer tests.

An `await` permits another actor job to change state. Capture/reserve owned work
before suspension, then recheck the relevant context in the synchronous consumer
turn. Test that changed context refuses stale installation, while irrelevant
later history does not invalidate a correctly retained older snapshot. Preserve
the existing pending-handle lifecycle and automatic resumption after saves cease.
These rules follow [actor isolation/reentrancy](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md#actor-reentrancy)
and [checked concurrency transfer](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md).

Use explicit outcomes for missing inputs, unsupported data, invalid claims,
retryable/ambiguous storage effects, stale applicability and complete success.
Pair uncertainty with the still-owned exact input or operation handle. A failed
derived update leaves accepted history committed. Cancellation requests settle
resources and preserve retryable work; they cannot prove transaction rollback.
The actual outcome cases must follow existing classification policy.

### Selective unique ownership

Prototype `~Copyable` only for a genuinely unique resource or one-use transfer,
such as a backup read-transaction lease or a repair-operation ticket, when it
simplifies the actor-owned implementation. `borrowing` grants scoped access;
`consuming` transfers a noncopyable value. Keep exact immutable bytes, verified
history facts and ordinary identifiers shareable. [Swift noncopyable types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md).

Noncopyability restricts reuse of a particular value, not repeated issuance of
two tickets for the same logical operation. The owner still serializes issuance
and checks identity/context. `consuming` on a copyable value permits copies;
dropping a unique ticket remains possible. Thus persistence and crash-idempotency
come from committed identities and reopening, while language ownership helps
with in-process transfer. Keep fallible commit/activation explicit rather than
performing it in `deinit`. Retain the existing cleanup bridge wherever a new
ownership wrapper would make release ordering harder to verify.

## Critical production-path scenarios

Each scenario has a valid companion, a reached named boundary, independent
expected results, prohibited effects and a specific mutation. Exercise the real
issuer **and** consumer; consumer-only tests are labeled separately. Run both
profiles with encrypted private pages. Recovery children receive surviving
files and normal selection/unlock inputs, not the parent's expected graph or
acknowledgment log.

### T01 — Older snapshot plus durable and pending newer work

Build a snapshot after edit E. Accept a later edit F or Delete D, with variants
holding its callback or failing materialization; independently retain a still
pending generation P. Rebuild from the snapshot and reopen. Also deliver a
concurrent branch and one selected third-writer descendant outside its cut.

Assert E and all committed later actions remain in exact retained history with
complete groups. Current and editing context reflect the full accepted union;
pending P stays owned and is cleared only by its matching receipt. Old snapshot
completion never reinstalls E into a newer live model. Repeat acceptance before
snapshot assembly, during worker suspension and before derived installation.
Mutations: skip the tail, treat snapshot as latest authority, or clear pending
work by birth alone. Contracts: `TC-START-01`, `TC-DUR-01/06`, `TC-ASY-01`.

Check P in the live delayed-completion schedules. Crash variants assert survival
of committed/retained inputs according to the selected fault model, not arbitrary
unpersisted RAM. The parent never supplies its pending-work log to recovery.

### T02 — Plausible snapshot values with wrong hidden history

Use small post-edit histories with concrete expected identities: reciprocal
conflict copies followed by output deletion/new source revision; automatic
delete/edit preservation followed by independent copy editing and late covering
Delete; fresh-birth Restore; overlapping Undo/Redo and multi-note actions.
Verify their heads, attention/dispositions, retirement/provenance, Recently
Deleted exclusions and Undo/Redo outcomes, as well as body/title/labels.

For each fixture alter one snapshot field/index, repairing framing, digest and
AEAD where applicable so it reaches semantic verification. Include body-equal
states with different represented revisions/action context. Correct neighboring
snapshots pass; wrong claims fail without changing accepted history/private
state. An unsupported snapshot has its own outcome. Mutations: omit an index
comparison, flatten provenance or certify only current values. Contract:
`TC-START-01`, plus the existing action/conflict contract observations.

### T03 — Page assembly, rejection and complete acceptance

Permute a small root, multiple pages and multiple history prerequisites through
candidate retention, validation, acceptance and restart. Include duplicate
delivery, an accepted shared page, a missing page, a contradictory page and an
unsupported prerequisite. A rejected root must not disqualify valid shared bytes
for another valid root. Dependency objects may also contain complete operations
outside the represented cut; a cut through an action group must fail.

Assert exact candidate bytes survive, preview/editability remain distinct, and
waiting reasons name the actual dependency. The complete batch establishes
acceptance/pin/wakeups together; extra accepted history is subsequently applied.
After required delivery or finite editing interference, work progresses without
another event. Mutations: candidate-as-accepted, partial manifest acceptance,
object-membership-as-causal-observation, missed wakeup, or root/page circular wait.
Contracts: `TC-START-01`, `TC-LIMIT-02`, receive-resumption/rejection obligations.

### T04 — Large initial construction and complete rebuild

Import zero notes and multiple batches/pages with distinguishable notes, labels
and untouched sentinel values. Cut construction before ImportComplete, during
verification, after history commit and during derived installation; fail recovery
once more. Include missing and contradictory imports with otherwise valid bytes.

Only the complete original count/digest/group commitment enables editable
activation. Every committed imported identity/value recovers; no partially built
candidate is published. Bound temporary buffers and per-turn work as counts
increase; test wide continuation indexes and multiple groups in one envelope.
Exercise manifest paging and the nearest legal count/length boundaries, verifying
representability under all other limits. Complete legal inputs pass; unencodable
inputs have explicit outcomes rather than truncated manifests or editable subsets.
Mutations: verify only a prefix, skip a group, publish after one page or discard
the only committed required batch on cancellation. Contract: `TC-START-01`, `TC-LIMIT-02`.

### T05 — Derived invalidity versus required data loss

Start with accepted history, valid nonempty settings and retained pending groups.
Separately corrupt/omit a current cell or context; corrupt/remove a required
object named by the surviving pin; make required private records unreadable;
provide wrong credentials, an unsupported version or permission denial.

Healthy history permits complete derived reconstruction while preserving the
private groups. Known required-history loss blocks editable success even with a
usable optional snapshot or apparently valid current rows. Unsupported/access/key
failures retain their explicit classification. Repeated failure while recording
damage cannot make the current owner resume healthy admission; a later normal
opener handles a surviving damage marker or diagnoses damaged evidence when
encountered. This adds no mandatory scan of every old object. Preserve original
data/journals.

Also test complete Local State loss with explicit reassociation: reconstruct only
the available history and disclose the lost private state. Detection of an erased
unknown leaf is impossible if all independent evidence of it was erased. Mutations:
treat the database as a disposable cache, omit a damaged row silently, reset
settings, or use `SQLITE_NOTADB` alone as proof of corruption. Contracts:
`TC-START-01`, `TC-REPAIR-01`, `TC-DUR-04`.

### T06 — Latest preview, frozen input and restart identity

Durably retain latest A for one pending item, then retain B while an admitted operation keeps A
frozen. Include nonempty settings and distinct reservation/action/link markers.
Fail replacement/settlement writes, hold completions, disappear the source file,
and crash twice. Commit the exact import, omit its receipt, then independently
edit/delete its birth before recovery.

After each transaction cut, all required group references resolve to exact
retained payloads. Failed B replacement leaves A available; completed B replacement
does not release frozen A. Absence/read failure preserves the last readable input.
Recovery finds the exact committed operation despite later changes and never
imports again merely because a receipt is absent. An uncommitted reservation
returns to the appropriate fresh decision path, not replayed consent. Newer B
remains independently owned until handled. Unsupported/partial private groups
are preserved and diagnosed rather than converted to valid decisions.

Mutations: early payload release, overwrite frozen A, identify completed work by
current body/liveness, or replay reservation as approval. Phase 4 qualifies the
codecs/transactions/reconstruction boundary with real ordinary history; Phase 6
adds actual file admission and fresh physical association. Contracts:
`TC-IMPORT-01`, `TC-DUR-04`, private-state requirements.

### T07 — Backup captures one state, including live-WAL work

Capture accepted prefix H, settings P and exact usable descriptors using the
specified keyed backup/read transaction. Keep committed work in the live SQLite
WAL. During bounded copying, commit H+1, change settings and add another same-key
descriptor. Normal writes must continue. Interrupt backup steps, destination
sync/close and verification; exercise reader/WAL budget exhaustion and cancellation.

Independently inspect the backup's captured prefix/closure, current catch-up and
private groups, then reopen with normal credentials. It must represent the
declared captured state, not mixed generations or later RAM edits. Every outcome
releases the reader and capture fence, preserves source history/journals and
distinguishes partial destination from completed backup. A long reader triggers
the specified bounded cancel/retry behavior rather than blocking saves without
limit. Mutations: copy only the live main database, capture settings/descriptors
from another cut, or certify before destination reopen. Contracts:
`TC-REPAIR-01`, `TC-DUR-06`, `TC-KEY-01`.

### T08 — Complementary repair, unique work and committed provenance

Let private history contain G+L and a repository/selected backup G+R, while the
surviving pin requires both. Include a unique unpublished action and frozen
pending payload available only privately. Damage selected pages/rows, salvage
through normal recovered SQL on a working copy, validate exact immutable bytes
and private groups, then rebuild a fresh sibling. Fail copy, pin/private commit
or fresh verification, followed by a second recovery failure.

Assert exact union coverage and preservation of the unique work. Remove L from
every source: complete activation fails and remaining evidence stays intact.
Acceptance flags/current rows alone cannot certify recovered history. Valid bytes
from low-level recovery may be deleted or uncommitted remnants; quarantine those
without independently established committed provenance. A page error closes
that attempt and uses the specified fresh working-copy connection. Partial
private groups produce an honest recovery limitation, never automatic consent.
Mutations: choose one source by date, trust recovered flags, drop unpublished
work, or salvage in place. Contract: `TC-REPAIR-01`.

### T09 — Unlocking route and selected-store activation

Prepare a fresh sibling and its required descriptor copies. Reopen/verify through
the production opener before attempting cutover. Cut at candidate durability,
credential verification, expected-selection capture, staged record write/sync,
replacement, directory barrier and readback. Introduce EIO/ENOSPC/permission
failures, a competing selection generation, second owner or same-path replacement
with identical collection bytes. Keep both original and replacement candidates.
Include symlinked, wrong-kind, foreign and inaccessible candidate/selection
occupants: preserve and classify them without blind replacement or permission changes.

Candidate verification alone changes no selection. A failure before replacement
leaves the old selection; once replacement may have happened, report the actual
success/ambiguity outcome. A qualified successful cutover selects only the
verified complete reopenable replacement. For ambiguous or permitted persistence-loss outcomes,
read back the surviving record and reverify its exact target; preserve both
candidates and never guess from names/dates. Do not demand old selection after
an effect that may already have completed. The actual platform primitive defines
the allowed outcome set; test its file and directory barriers separately.

Password-free backup/recovery works with Keychain unavailable. Encrypted recovery
requires an authorized secret and retained same-key descriptors; a wrong key or
inaccessible descriptor is not permission to activate an empty/public store.
Check wrong collection/profile/store/association/key and stale selection evidence
at the actual consumer. Fresh origin allocation follows activation. Mutations:
accept a decoded record as authority, skip fresh reopen, activate before unlock
evidence, or retire old data after an ambiguous effect. Contracts:
`TC-REPAIR-01`, `TC-KEY-01`, `TC-EVD-01`, local `TC-ROOT-01`.

### T10 — Repeat delivery, cancellation and finite interference

Duplicate/repackage equivalent history, deliver children before multiple parents,
pause optional verification while saves progress, then stop editing and deliver
nothing further. Cancel before sealing, after candidate retention and after
acceptance. Resume/reopen repeatedly, with selected storage failures on rejection
and ready-work transitions.

Assert one logical effect, exact retention coverage, durable blocking reasons and
automatic progress when required evidence/storage becomes available. Cancellation
does not erase owned admitted inputs or retract committed acceptance. Optional
failure leaves ordinary durable saves successful. Mutations: duplicate logical
update, missed automatic resumption, rejection loss or completion-as-rollback.
Use existing receive/lifecycle tests and `TC-LIVE-01`, `TC-LIMIT-02`.

### T11 — Optional codecs and maintenance preserve the same contract

After the P0 bundle, vary zstd/raw current rows, dictionaries and dispensable read
hints, including lost/corrupt dictionary or hint. Exercise idle VACUUM against
new save admission, cancellation, low space and crash. Compare full values,
context, history/pin/private groups with the uncompressed baseline.

Invalid derived encoding takes the rebuild path if required history is healthy;
required database/history damage takes repair. No physical optimization replaces
semantic verification or weakens save acknowledgment. Healthy returning opens
with no pending required work forbid historical BLOB/operation reads. Exceptional
replay can be proportional to history; measure its yielding/progress separately.
Mutations: truncated decoded values, required hint, dropped private rows or
maintenance delaying a save past its qualified budget. Contracts:
`TC-ZSTD-01`, `TC-PERF-01`, `TC-LIVE-01`.

## Make the test evidence difficult to fool

1. **Keep independent observations.** Extend the existing history inspector with
   independent general-root/page parsing and checked preimages. Use literal byte
   fixtures and hand-declared small-history values/references alongside production
   full-replay comparisons. Inspect committed membership, expanded pin coverage,
   private links and normal fresh-open results. Two reducers agreeing or two
   peers converging can still conceal the same omission.
2. **Reach the specific decision.** Use native parameterized Swift Testing cases
   with per-case owned directories and explicit completion gates. Wait for the
   actual operation/task and a reached boundary, rather than sleeps. A
   confirmation count alone does not wait for asynchronous work. Tests sharing a
   store form one controlled scenario; unrelated cases remain independent.
3. **Enumerate small connected schedules.** Start with two writers, two changing
   notes and an untouched sentinel; add selected third-writer branches. Enumerate
   root/page/prerequisite orders and meaningful before/after transaction,
   callback, view-installation and cutover positions, with zero/one/two crashes.
   Keep codec defects, ownership races and disk faults focused rather than taking
   one unfinishable Cartesian product. Generated larger histories record both
   seed and actual schedule; shrink while preserving valid closure and the same
   reached failing assertion.
4. **Distinguish failure classes.** Process kill forgets memory/callbacks. Simulated
   persistence loss uses an explicit barrier/namespace model. Later corruption
   is injected separately and tests detection/repair. Neither process kill nor a
   VM reset automatically qualifies physical power loss. Fault hooks bracket
   real effects and do not add an `await` inside synchronous transactions or
   invent partial visibility inside an atomic namespace primitive.
5. **Challenge the test runner.** Require nonzero named discovery, a valid baseline,
   a reached fault and assertion-specific mutation failure. An earlier framing
   rejection cannot qualify semantic verification; setup errors cannot qualify
   compiler protection. Replay first-failure artifacts instead of retrying to green.
   Extend the existing VFS/process, fixture, compiler and mutation drivers, with
   independent self-tests for their new hook/decoder/discovery paths.

### Compiler and same-type/wrong-context test ledger

Apply these to actual production types through
`tools/test-storage-runtime-types.py` and the existing static clients, in debug
and optimized configurations. Each negative compile case has a positive peer and
must fail at its marked source location for the intended reason.

| Static challenge | Dynamic companion that types alone cannot establish |
| --- | --- |
| Pass preview/parsed snapshot to a verified-basis consumer | Fully protected but semantically wrong claims reach verification and fail |
| Construct/mutate/decode verified basis, acceptance receipt or replacement permission from an ordinary client or sibling file | Actual issuer creates evidence; same-type evidence from another cut/store/session/key or stale view is rejected by the real consumer |
| Substitute an object locator for an operation frontier, or interchange graph-role reference sets | Incomplete/nonmaximal/wrong-scope sets of the correct type fail semantic checks |
| Access isolated connection state synchronously or transfer retained mutable SQL resources out of the owner | A suspension admits interference; unchanged context succeeds and stale installation/publication fails |
| Consume the same adopted noncopyable lease twice | Early drop/cancel releases resources; duplicate logical requests and post-crash retries remain idempotent through the owner/store |
| Omit a supported private/recovery outcome in an internal exhaustive switch | Literal classification fixtures distinguish absent, inaccessible, corrupt, unsupported, wrong-key and ambiguous outcomes |

Audit unchecked conformances, unsafe annotations, public raw factories and
decoding surfaces as part of each new boundary. Retain strict memory-safety and
warnings-as-errors settings; C diagnostics/sanitizers and actual filesystem
qualification complement them. A compile-blocked mutation is static evidence,
not a runtime mutation kill. Runtime tests must exercise the compatible-type
cases that the compiler necessarily permits.

## Delivery gates and limited experiments

| Increment | Required evidence before widening scope |
| --- | --- |
| 4A | Record/byte fixtures, actual issuer restrictions and T02/T03 semantic verification; T01 capture preserves an older valid cut |
| 4B | T01–T05 and T10 through real acceptance/materialization/opening; healthy startup and first-save work-count regressions; both profiles |
| 4C | T05/T06 private record/transaction preservation and precise classification, without claiming Phase 6 physical association |
| 4D | T07–T09 with real SQLCipher backup, fresh-process verification and qualified expected-selection installation |
| 4E | Extend T07–T09 to repository-only available-byte copy versus complete private backup versus explicit fresh current-state export; retain the copy plan's unknown/unreadable-file cases |
| 4F | T11 correctness, aged equivalent-load measurements and required-write priority/cancellation; optional acceleration earns its complexity |

Use the [existing model correspondence](phase4-startup-recovery-plan.md#testmodel-qualification-and-completion)
as ordering/scheduling evidence. The new root/page semantics and Swift issuers
require executable tests. Extend a focused model only if a concrete new
cross-component transition is uncovered; preserve independent assertions and
validate counterexamples rather than weakening them. Phase 5/7 still qualify
actual provider, credential-adapter and UI behavior.

The 2026-10-02 local language experiment used Apple Swift
`6.4.0.34.1`, Swift 6 mode, strict memory-safety/warnings-as-errors and optimized
SIL generation. Six positive/negative pairs confirmed issuer-file access,
nominal-role separation, actor access, retained non-Sendable connection isolation,
noncopyable consumption and exhaustive switches at the intended diagnostic
locations. A seventh positive probe demonstrated that a copyable `consuming`
parameter permits repeated use. A deterministic actor-gate executable showed
unchanged-generation success and refusal after an intervening actor job.

These were isolated language sketches in a synthetic temporary directory, not
production Phase 4 contract tests or platform qualification. Repeat the checks
against the actual modules as they are implemented. No new Phase 4 runtime suite,
TLC run or physical power-loss result is claimed by this planning update.
