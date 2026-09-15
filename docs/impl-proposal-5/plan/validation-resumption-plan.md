# Resume received-history validation after local saves

Status: implemented; see [qualification results](validation-resumption-results.md).
Date: 2026-09-16.

## Outcome and minimal design

When local saves invalidate received-history validation, continue automatically
after those saves settle. A healthy open session with all required evidence and
only finitely many interfering saves must eventually process its retained
candidate, even if no further file arrives and the application stays open.

**Keep the existing asynchronous receive operation alive across this temporary
interruption.** It already owns the receive reservation and the exact input is
already in the durable queue. Wait for an active local save using the session's
existing completion notifications, then retry the same queue.

Add no database fields, tables, sidecars, timers, stored task handles, pending-work
flags, generation counters or additional queues. Reuse `receiving`, `inFlight`,
`drained`, the existing history worker and `ready_objects`. The continuation held
in `drained` is temporary waiting state in an existing mechanism. A typed internal
interruption identifies why the current attempt stopped.

The observable trade-off: a receive call can remain asynchronously pending longer
instead of returning `busy` solely because saves repeatedly changed its history.
Local persistence continues to interleave; the caller's thread is free while
awaiting. This preserves the existing single-receiver policy. An early-return
background-receive API would require separate worker lifetime/observation state
and is outside this small change.

## Source basis before this change

- `HistoryDatabase.swift`: `acceptScheduled` made two attempts against
  an exact accepted prefix, then throws the general `StorageError.busy`.
- `ReceivedObjects.swift`: `receive` owns `receiving` until return; `drainReady`
  preserves a candidate when acceptance throws a transient failure.
- `Commit.swift`: `finish` clears `inFlight` and resumes `drained` waiters on every
  exit, including failures. Exact sealed inputs and receipts are already owned.
- `LocalStore.swift`: `quiesce` stops new admission and waits for owned receive/save
  work; reopening drains the durable queue.
- [Local storage contract](../LocalStore.md), [first-save contract](first-save-reopen-contract.md)
  and [language/testing strategy](swift-storage-conformance-testing-strategy.md)
  retain their complete-validation, exact-byte, ownership and recovery rules.
- [Specification](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state),
  [ADR 0004](../../adr/0004-make-local-history-durable-before-external-effects.md),
  [ADR 0010](../../adr/0010-separate-local-durability-from-provider-work.md) and
  [CONTEXT](../../../CONTEXT.md) separate parked evidence, accepted history and
  publication. Scheduling an attempt grants none of those later authorities.

## Implementation steps

### 1. Give history interference its own internal outcome

Introduce an internal typed error/result for exhaustion of the existing two
attempts specifically because their accepted-history prefix changed. Emit it
only from that branch of `acceptScheduled`.

Keep database `SQLITE_BUSY`, I/O errors, missing evidence, invalid data, failed
ownership checks and stale host captures distinct. Receive rejection must never
classify this scheduling interruption as malformed history. Local `persist/retry`
can keep returning its existing pending handle with public `busy` for this internal
condition; add the explicit mapping in `classify` so it cannot become `integrity`.
Public API signatures and wire formats remain unchanged.

### 2. Continue the owned receive instead of abandoning it

Wrap `drainReady` in a small actor-isolated loop inside the receive path:

1. Run the existing complete ready-queue drain.
2. On the typed history-interference outcome only, inspect `inFlight`.
3. While a local save is active, suspend through the existing `drained` continuation
   list. Recheck `inFlight` after every wake-up because another save may have started.
4. When no save is active, run the drain again immediately.
5. On ordinary completion, perform the existing catch-up and outcome lookup. Other
   errors leave through the current error path with durable evidence preserved.

Keep `receiving` reserved throughout. Reuse the durable queue and its exact bytes;
do not call public `receive` recursively, reinsert/reseal the candidate, reset its
identity, or issue success before its actual acceptance transaction commits.

The condition is **active storage work**, not keyboard activity. Waiting on
`commits.isEmpty` would be incorrect: a failed save can retain an owned pending
capture after its active attempt ends. That capture is handled by the existing
retry contract and must not strand this receive wait.

### 3. Close the wake-up race with condition-based waiting

Checking `inFlight` and appending its waiter must happen in one actor-isolated,
synchronous continuation-registration section. Reuse the same pattern as current
`quiesce`; do not perform a separate asynchronous check and registration.

Swift's continuation operation runs immediately in the current execution context;
resuming a continuation schedules its later execution. Keep registration on the
session actor and always loop on the condition after resumption. See
[SE-0300](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0300-continuation.md#detailed-design).
The implementation and deterministic tests must preserve that isolation under
both supported Swift compiler versions.

This covers both orders:

- Save finishes first: `inFlight` is already false; retry without sleeping.
- Receive waits first: `finish` clears `inFlight` and wakes it.

No notification needs to be remembered. A new save racing with a restarted check
can invalidate that check again, and the same complete validation/fences apply.
Repeated passes require actual accepted-history changes; generic errors do not
create an automatic busy loop. Once saves stop, the next compatible pass can finish.

### 4. Preserve lifecycle and failure behavior

- Keep the current quiesce behavior: stop new admission, allow already owned
  receive/save work to settle, then release the directory/database lease. The
  receive's wait condition is `inFlight`, not `quiescing`; quiesce itself is
  waiting for the receive, so waiting for quiesce to finish would deadlock.
- A quiesce attempt that later returns busy because an admitted local commit is
  still pending must not leave the receiver abandoned without a wake-up. Allowing
  its already owned continuation to settle avoids a separate restart flag.
- Caller cancellation retains the existing admitted-work ownership contract.
  Do not add cancellation checks that silently exit after durable queue insertion.
  Cancellation is neither a rejection nor permission to close the database under
  a suspended worker. Test this using the existing async API semantics; do not
  promise a new early-return cancellation interface.
- A process crash needs no saved continuation. Reopen discovers and drains the
  existing durable ready entry using ordinary journal recovery.
- EIO, ENOSPC, ownership loss, known damage and real database busy remain explicit
  outcomes. This plan provides automatic continuation for history interference,
  not an unbounded retry policy for failed storage.
- Missing prerequisites retain their existing parked/dependency behavior.
  Rejection-write failure qualification and blocked-descendant diagnostics are
  separate tests in this follow-up. No general queue-polling service is added.

## Executable validation

Use the existing real Runtime, exact sealed input, both provider profiles and
deterministic worker/completion gates. Test deadlines diagnose a hang; timed sleeps
must not arrange the intended interleaving. Keep note expectations independent of
the production reducer.

1. **Exhaust both attempts, then stop editing.** Invalidate two actual checks with
   successful local saves. Deliver nothing else. The original receive must finish;
   assert the received effect, both local edits' retained history, exact acceptance
   membership and the correct current values. Assert exhaustion was reached so
   the existing single-retry test cannot masquerade as this case.
2. **Last save already finished.** Complete it before the receive handles the typed
   interruption. It must retry immediately, without awaiting a nonexistent event.
3. **Last save still active.** Hold its completion after the history change, verify
   the receive is suspended, then release it. A new validation attempt and successful
   processing must follow from that completion alone.
4. **Another save starts before a woken receiver continues.** Recheck the condition;
   preserve the new save and eventual receive result without duplicate acceptance.
5. **Failed save completion.** Its active flag still clears and wakes the receiver.
   Any retained pending commit continues to require its existing exact-byte retry.
6. **Quiesce, failed quiesce and caller cancellation while waiting.** Require progress
   or the precise existing storage failure, single-resume continuations, complete
   lease ownership and no second concurrent receiver. Preserve queue bytes on error.
7. **Crash while postponed.** A fresh process receives only surviving storage and
   normal unlock/selection inputs. It processes the ready object on reopen exactly once.
8. **Failure categories stay separate.** Inject actual I/O/database busy and invalid
   input companions; require their original outcomes, preserved bytes and bounded
   work. No automatic retry or rejection may be inferred from a generic error.

Add targeted negative mutations for returning generic busy instead of continuing,
waiting despite an already-finished save, losing the completion wake-up, clearing
the ready entry on deferral, or releasing the receive reservation too soon. Each
must fail its named assertion after a passing, discovered baseline. Use test-only
gates below the real owner path, not caller-constructible acceptance evidence.

Run focused and full debug/optimized Runtime suites, affected mutation/type checks
and supported compiler/platform checks. This is scheduling work: existing TLA+
acceptance/closure invariants remain intact. Their current models do not prove
this concrete wake-up; document executable liveness evidence without relabeling
an existing safety check as a progress proof.

## Documentation and completion

On implementation, update LocalStore and the first-save contract to distinguish
bounded validation attempts from the continuing owned receive, and extend the
hardening report with actual test results. Keep unchanged broader limits:
large-bootstrap scheduling, batched validation and later reducers. Rejection-failure
and blocked-descendant work is implemented in the same follow-up with separate tests.

Complete when finitely many interfering saves followed by a healthy quiet session
lead to processing without another receive call, timer, restart or new persistent
state, and all error/lifecycle companions preserve the existing safety contracts.
