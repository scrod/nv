# Durable reminders for interrupted verification

Date: 2026-10-04. Status: implemented. See the [validation report](validation.md)
for the concrete replay codecs, checking coverage, executed tests and limits.
The [storage review](../storage-review-follow-up.md) preserves the starting evidence.

## Outcome and rationale

Retain a small durable reminder before an operation inspects accepted history
whose corruption could otherwise be forgotten after a failed diagnosis write.
Keep that reminder through the operation's final consistency checks. Reopening
repeats unfinished verification before publishing a complete editable collection.

The reminder belongs to a logical verification operation. File-reading batches
remain scheduling and performance details. A completed file read can feed a
later graph check, so completion of that read alone cannot release the reminder.

An unrelated crash with no unfinished verification follows ordinary indexed
startup. A small interrupted verification repeats its captured scope. An
interrupted whole-history verification can still require whole-history work.
Reducing that scope or persisting intermediate verification progress is separate
work, justified by measurements rather than required for this increment.

Normal uninterrupted operation gains durable bookkeeping. The time saving is
relative to a blanket history audit after every unclean session, especially for
long-lived collections. The correctness benefit is preserving the obligation to
rediscover damage when the later diagnosis transaction cannot commit.

## Authority and starting implementation

- [Specification](../../../iCloud-Drive-Support-Spec.md): START-01, CKPT-01,
  DUR-01, PUB-01, ROOT-01 and REPAIR-01.
- [ADR 0016](../../../adr/0016-repair-from-validated-immutable-copies.md): private
  history loss, conservative repair and healthy startup without replaying all history.
- [CONTEXT](../../../../CONTEXT.md): accepted history, required Local State,
  physical ownership, generation fences and edit admission.
- [LocalStore](../../LocalStore.md#concrete-returning-launch-algorithm) and
  [schema contract](../sqlite-local-schema.md#materialization-settings-and-reopen):
  present health latch, damage marker, private groups and startup sequence.
- [Swift boundaries](../swift-storage-library-proposal-v2.md),
  [conformance strategy](../swift-storage-conformance-testing-strategy.md) and
  [Phase 4 safety contracts](../phase4-data-safety-contracts.md): restricted issuers,
  contextual consumers, independent observations and failure qualification.
- [TLA coverage](../../../tla/README.md#private-sqlite-transaction-and-fast-start-mapping):
  acceptance, startup and reconstruction assumptions to refine during implementation.

Before this increment, `Database.checkingRetainedHistory` latched discovered damage in memory.
`DatabaseLane.perform` then attempts an idempotent `history-damage` insertion in
`private_groups`. A successful marker blocked reopening. The uncovered
boundary was interruption after discovery but before any successful marker commit.
`REVIEW-DAMAGE-1` and `test-storage-review-process.py` reproduce that boundary,
including repeated real write failures and a fresh recovery child. Their present
assertions require conservative reopening after a failed diagnosis; the durable
request supplies that protection.

This plan replaces the review's preferred blanket unclean-session audit with
captured verification obligations. At implementation, align the normative repair
wording, ADR 0016, CONTEXT, LocalStore, schema contract and model correspondence
with the stronger completed guarantee. Until qualification, keep the existing
failure boundary and known issue explicit in implementation reports.

## Scope and minimal state

Use the existing encrypted private database for both provider profiles. Store
one independently versioned private group per active verification, using a
reserved key prefix and a freshly allocated verification ID. The existing
`private_groups` index supports exact lookup and a bounded prefix range; qualify
the actual query plan. Reminders are host-private required state.

Each record contains a versioned replay recipe: verification kind, exact input
references or a captured accepted-history boundary, and any validator/context
version needed to repeat the same checks. Bind it to the selected local store
and collection through the validated header and its explicit scope. Freeze the
complete layout and independent byte fixtures in gate V1 before enabling writes.

Use a small explicit Swift enum for the implemented recipes, such as checking
an accepted object at an exact locator or checking a retained graph through a
particular accepted prefix. A note or snapshot recipe must include every input
its final check uses. Local acceptance sequences identify a prefix in this
specific private store; they retain their existing bookkeeping meaning.

Recipes normally contain identifiers and counters. Input bytes already retained
durably are referenced by exact identity. A recipe depending on otherwise volatile
input must durably retain that input with the reminder, or be redesigned to repeat
an equivalent check of retained evidence. A note ID alone is insufficient when a
later check needs the original candidate, revision, scope or verifier version.

Keep records proportional to outstanding work. Apply bounded admission and
backpressure before starting protected checks; completed records are removed.
Choose and qualify the internal admission bound against the existing save/receive
scheduler. Failed completions retain their slots until retried. Reopening claims
existing records rather than issuing another generation of the same work.

Several active operations may own reminders. This preserves yielding to saves
without making an entire history traversal hold a global verification slot.
Reminders live alongside existing durable work; no independent scheduler,
per-record progress log or long-lived history cache is introduced by this plan.

## Coverage inventory and reuse

Before implementing the first recipe, inventory every path that can classify
accepted history as damaged. Include `acceptedEnvelope`/payload/operation/action
reads, direct SQL/index checks, graph assembly and reduction on the history
worker, snapshot verification, reconstruction, Note History and compensation.
Some checks bypass the envelope helper or run after all SQL reads finish.

For each path, record: the final check, exact replay inputs, error classification,
existing durable restart obligation, and the owning completion boundary.

Reuse durable bootstrap/receive/reconstruction work only when its normal reopen
path repeats all relevant checks and preserves its inputs until those checks
finish. Show this with a production-path test. Presence of a queued object or a
lagging view by itself does not establish coverage. Use a new reminder where
existing work does not provide that guarantee. Always-repeated opening checks
can similarly supply coverage for the exact required state they inspect.

Nested reads share their enclosing verification's protection when its recipe
covers their complete validation. This keeps the number of durable writes tied
to logical operations rather than the number of records traversed.

## Lifecycle, ordering and failure semantics

1. **Capture and admit.** Under positive ownership, validate caller context and
   freeze replay inputs. Commit the reminder and any uniquely owned inputs before
   performing its corruption-detecting checks. Issue an internal handle only
   after that commit is established. Failed admission preserves caller inputs
   and starts no uncovered verification.
2. **Verify.** Read bounded owned bytes on the database lane and run the existing
   checks on the appropriate worker. Preserve the captured prefix and normal
   yields. Keep the reminder through cross-record checks and reduction that can
   still diagnose accepted-history damage.
3. **Complete successfully.** A restricted success value identifies the exact
   verification, recipe and owning connection. In a synchronous transaction,
   recheck ownership, health and that exact reminder, then remove it. Deliver the
   completed result once settlement is known. If derived rows are also installed
   in that transaction, keep their existing view/history applicability checks.
4. **Discover damage.** Immediately latch the existing live health gate. In one
   independent transaction, insert the existing damage marker and settle the
   affected reminder. Either the old reminder survives or the damage marker
   commits. A successful sibling verification cannot clear the health latch.
5. **Handle other failures.** Transient I/O, cancellation and uncertain completion
   retain the reminder and owned inputs for retry. Invalid incoming claims and
   caller context errors keep their existing distinct classification; they do
   not become corruption of accepted history. Settle an invalid-candidate path
   only after its retained-history checks and required rejection bookkeeping
   have reached their proper terminal outcome.
6. **Resolve ambiguous commits.** Query recovered exact identities under the
   owned store. A present record is replayable; successful removal may be retried
   by that operation after its known successful verification. An absent record
   alone supplies no verification success to an unrelated caller. A damage
   marker or uncertain database health dominates ordinary completion.

A saved user action retains its existing acceptance acknowledgment boundary.
Later derived verification failures preserve the accepted action and its receipt.
When acceptance uses protected verification, preserve a conservative reminder
until its complete obligation is discharged, or settle it with acceptance when
the same transaction and immutable inputs establish that outcome.

## Reopening, cancellation and shutdown

After ownership/unlock and minimum header/private-state validation, inspect the
damage marker and pending verification groups using indexed lookups. A committed
damage marker follows the existing repair path. Otherwise replay pending checks
under the startup publication gate, then continue required ready work, indexed
catch-up and the consistent current-row capture. Express exact ordering with
existing bootstrap/reconstruction dependencies; replay reads captured accepted
prefixes even if later history has arrived.

Replay performs verification and settlement. It does not reissue a user's Undo,
Delete, conflict choice or other command. Those mutations retain their separate
captured inputs, admission identities and consent rules.

Pending verification is uncertainty about unfinished checks, not proof of
corruption. Successful replay allows ordinary opening. Missing required evidence,
malformed required reminder state or an unsupported required verifier version
produce explicit recovery/unsupported outcomes. A read failure preserves the
record. Retry needs no additional provider delivery. Old callbacks remain bound
to their closed connection; a reopened owner obtains fresh in-memory handles.

Cancellation requests stop work at safe boundaries while durable obligations
remain. Retryable active work resumes through the existing local-work mechanism
after finite interference ends, or through reopening after shutdown. Avoid
polling loops and unbounded automatic retries on persistent storage failure.

`quiesce` currently waits for commits and required receives. Extend ownership
settlement to every protected verification, including optional/background work:
drain it, or leave its reminder durable while safely ending its connection-bound
work. Generic cleanup and `deinit` release resources; successful verification is
the authority to remove a reminder. A healthy sibling completion cannot stand
in for an unfinished or failed operation.

Backups retain pending groups and their referenced private inputs. Later repair
must preserve each unresolved obligation: verify its original scope or explicitly
rebind it after proving equivalent retained inputs in the fresh store. Local
sequence values from one store cannot simply become prefixes in its replacement.
Document this requirement alongside the existing required-private-state repair
gate; provider-only rebuilding cannot silently certify those private obligations.

## Swift-enforced boundaries

- Use nominal verification IDs, an exhaustive recipe enum and explicit pending,
  verified and uncertain outcomes. Bound and validate every recipe during decode.
- Keep constructors for admitted handles and verified completion values private
  to their actual issuers. A decoded record establishes a replay request.
- Make protected retained-history access consume an internal admitted context or
  verified existing-work context. Audit alternate helpers and same-module access
  so arbitrary callers cannot substitute a Boolean or manufacture coverage.
- Match success to the exact handle/recipe/session at its consuming transaction.
  Swift distinguishes roles; runtime checks distinguish two values of one role.
- Keep SQLite connection state actor-isolated and transactions synchronous.
  Workers receive checked `Sendable` immutable values; final consumers recheck
  applicability after suspension.
- Use a noncopyable ticket only if it simplifies the actual asynchronous call
  sites. Durable IDs and conditional settlement provide retry correctness even
  when a handle is dropped. Keep fallible settlement explicit.

## Implementation sequence and acceptance gates

| Gate | Work | Required result before expanding |
| --- | --- | --- |
| V0 — Coverage and contract | Complete the check/replay inventory, choose smallest recipe variants, specify completion and error boundaries, align planned normative/model changes | Every damage-producing path has an identified restart obligation; graph checks remain covered after reads finish |
| V1 — Private recipe and admission | Freeze codecs/fixtures and reserved key prefix, add issuer-restricted handles and indexed CRUD, establish admission/backpressure | Both profiles survive reopen; wrong contexts/versions fail precisely; failed admission performs no protected read |
| V2 — Exact-object lifecycle | Protect real retained-object inspection, add replay for that recipe, persist successful/damaged outcomes, handle uncertain writes and duplicate completion | Existing old nonfrontier damage witness passes after repeated marker failures and a fresh process; live publication stays blocked |
| V3 — Complete operation coverage | Cover worker graph checks, commands, snapshots and reconstruction; qualify existing-work reuse, nested calls and concurrent verification | Successful file decodes followed by a late graph failure retain restart coverage; saves can still run between reads |
| V4 — Startup and ownership | Add indexed replay, retry wakeups, quiesce/cleanup fencing and required-private-state handling | Healthy interrupted checks recover; unrelated crashes add no all-history scan; repeated recovery failures preserve obligations |
| V5 — Qualification and documentation | Run the matrix, compiler probes, mutations, focused model and platform/work-count checks | Remove the narrow known issue only when the actual guarantee passes; publish evidence and remaining limits |

Update schema documentation, its runtime resource if needed, private-record format
tables and independent fixtures together. The unreleased private format can
change directly; epoch-4 application import/export qualification remains intact.
Keep provider envelope formats and application interaction code outside this
increment. Later decoding/query optimizations can reuse these verification
boundaries without redefining durability.

## Production-path test matrix

Apply TC-START-01, TC-REPAIR-01, TC-ASY-01 and the relevant durability/evidence
contracts. Use both provider profiles, exact independent bytes/values, untouched
notes and actual issuer/consumer paths. Each failure case has a valid companion
and an observed reached boundary.

| Case | Schedule | Independent required observation |
| --- | --- | --- |
| VR01 — Admission ordering | Fail before/during/after reminder commit; hold its callback | Protected inspection starts only after durable admission; ambiguous admission reuses the same identity |
| VR02 — Lost diagnosis | Inspect corrupt old nonfrontier history; fail damage-marker writes repeatedly; terminate; repeat a failure on reopening | Exact obligation or damage marker survives; complete editable publication remains blocked; accepted contents/identities and private settings survive |
| VR03 — Healthy interruption | Kill before a read, after successful reads, after verification and after successful settlement but before callback | Remaining exact checks resume; settled checks stay settled; correct current notes and editing context reopen |
| VR04 — Late semantic failure | All envelopes authenticate/decode; block final worker check, then expose a genuine retained graph/index inconsistency | Reminder remains until final validation; failed diagnosis plus restart rediscovers the same defect |
| VR05 — Concurrent operations | Hold A; complete B; fail A; deliver stale B completion; include a later ordinary save | B settles only B; damage continues to block publication; accepted save remains durable and its matching pending-generation rules hold |
| VR06 — Context | Same-type wrong recipe/store/session/token; reopen while an old completion is held; advance accepted history after capture | Wrong evidence cannot settle work; old-prefix verification can succeed while obsolete presentation is rejected |
| VR07 — Classification | Malformed incoming object, wrong caller locator, missing accepted bytes, unsupported recipe, transient read failure | Distinct exact outcomes; unrelated accepted history survives incoming rejection; required state never becomes an empty healthy result |
| VR08 — Cancellation/close | Cancel nested/optional work before and after final check; overlap quiesce and worker completion | Inputs/reminder survive unfinished checks; owner lifetime is safe; finite interference ends in retry progress without new delivery |
| VR09 — Existing obligation | Repeat VR02/VR04 using each claimed bootstrap/receive/reconstruction coverage path | Actual reopen revisits every required check; a queued unrelated input cannot satisfy coverage |
| VR10 — State preservation | Corrupt an enumerated recipe or lose an input it names; preserve reminders in a consistent backup and reopen | Explicit required-state recovery outcomes; same-store backup preserves exact scope; repair tests reject blind cross-store sequence reuse |
| VR11 — Work bounds | Otherwise healthy settled stores with fixed current notes and growing 64/256/1,024-action histories; zero reminders, one exact-object reminder, then a whole-prefix reminder | Zero-reminder recovery adds no historical walk; exact-object replay avoids unrelated payloads; whole-prefix cost is reported honestly |

Extend `StorageReviewTests.swift`, the fresh-process review driver and the common
qualification driver. Inspect SQL state and envelopes independently of runtime
success flags. Recovery children receive surviving store files and normal unlock/
selection inputs, never the parent's diagnosis, expected notes or acknowledgment
log. Model process termination, failed writes, simulated persistence loss and
later corruption as separate classes. Real SQLite/VFS fault injection must prove
that the intended operation was reached; repeated failure is a required schedule.

Compiler probes need valid clients, exact expected source-line failures and
same-module/same-file construction challenges. Include bypass of admission,
forged success and mutable recipe attempts, plus actual same-type wrong-context
consumers. Extend exhaustive-switch probes for new recipe variants.

Targeted mutations: read before admission; ignore failed admission; release after
decoding but before semantic checks; clear on cancellation; clear all reminders;
settle the wrong token; publish before replay; use a current prefix instead of the
captured prefix; convert corrupt accepted history into incoming rejection; and
assume an existing queue provides replay when its input/check was already removed.
Require designated assertions, nonzero discovery and passing unmutated companions.

## Focused model and performance qualification

At implementation, add a small verification/reopen model or a focused extension
of the existing SQLite fast-start model. Use two verification operations, two
objects and a small accepted prefix, separating durable reminder admission,
reads, final semantic checking, successful/damaged settlement, crash and reopen.
Permit repeated write failures, delayed sibling completions and one corruption
event. Keep the model finite through explicit finite inputs rather than pruning
the contested transition.

Assert that observed accepted-history damage retains either a committed damage
marker or an unresolved replay obligation; old completions cannot settle another
operation; startup cannot publish complete editable success before replay; and
accepted history/pending input ownership survives. A successful-verification bit
must follow the modeled checks, with raw-read success separate from later graph
failure. Require witnesses reaching the failure and healthy recovery, designated
negative controls and progress after finite interference/storage failures cease.
Document what the model assumes about SQLite transactions and exact replay inputs.

Measure admission/settlement transactions and synchronization cost, historical
reads/decoded bytes, pending row count/size, recovery latency and local-save delay
while verification is suspended. Include ordinary current-state saves and the
first save after reopening; preserve their existing zero-ancestor assertions.
Optimize settlement batching only after the simple lifecycle qualifies, and only
when each operation's full validation has completed. Reminder count/bytes must
return to baseline after healthy settlement; record failures keep owned records.

Run affected tests in debug and optimized builds, independent fixtures/schema
checks, actual construction probes, mutations and fresh-process schedules on
macOS and Linux with current strict flags. Run applicable TLA configurations
when the model changes, and sanitizer qualification for altered actor/cleanup
paths. Preserve existing Linux executable-permission checks. Record unavailable
Intel/macOS 11 execution and physical power-loss qualification separately.

## Completion and limits

Completion requires the current `REVIEW-DAMAGE-1` known-issue blocks to become
ordinary passing assertions on actual production paths, plus coverage of later
semantic failures. Update the review report and conformance driver accordingly;
the other six review findings remain independently tracked.

The guarantee relies on successfully committed replay inputs surviving under the
qualified storage failure model. Total rollback, destruction of those inputs,
or undetectable removal of an entire obligation and its evidence remains outside
that guarantee. Malformed surviving groups and missing inputs they name have
explicit recovery outcomes. Future corruption of previously verified, unread
history remains detectable when it is subsequently inspected.
Persisting verification progress and narrowing global graph queries remain
separate improvements. A whole-history job interrupted mid-verification may
still repeat that work; healthy unrelated crashes keep indexed startup.
