# Phase 4A/4B: durable local snapshot acceptance

Date: 2026-10-03. Scope: gate **S1** of the
[snapshot acceptance/recovery plan](phase4-snapshot-acceptance-recovery-plan.md).
The [earlier report](phase4-general-snapshot-validation.md) covers canonical
records, complete preview assembly and semantic claim validation. This increment
connects that checked boundary to the existing SQLCipher acceptance transaction.
Received-candidate assembly, complete new-client bootstrap and snapshot-based
current-row rebuilding remain S2–S4.

This report preserves the S1 increment's executed results. The later
[startup/scoped-query qualification](phase-4-improvements/startup-and-scoped-queries-validation.md)
updates its 22-schedule process campaign to checked host publication followed by
background optional-root acceptance. Required snapshot prerequisites still finish
before publication; independent optional roots stay durably queued until then.

## Production lifecycle

1. `captureGeneralSnapshot()` freezes neutral values and continuation claims from
   one complete accepted history prefix. It reconstructs and audits that prefix
   through the existing exceptional history-reading path. Ordinary healthy
   returning startup keeps its indexed current-row path.
2. `persistGeneralSnapshot(capture:)` checks the issuing store/session and reserves
   one construction operation before suspension. Its private actor emits the
   existing canonical tree through the collection's sealer. Snapshot and ordinary
   save emissions share the session's allocation function; allocation is reserved
   before an asynchronous handoff. Default data chunks are 256 KiB.
3. Each exact sealed page is committed to `objects` as a candidate. A complete
   retained root additionally owns `ready_objects` work. Pages without a root
   remain recoverable candidates. Root/page candidates have no logical action
   membership and cannot independently change notes.
4. Complete assembly resolves actual retained bytes. Semantic checking resolves
   every stated operation/action occurrence, requires the complete original
   bootstrap and action cut, and compares all neutral claims with that cut's
   reduction. A private initializer issues `CheckedSnapshotAcceptance`, binding
   that result to the live database connection, collection/profile, bootstrap and
   checked prefix.
5. The existing synchronous acceptance transaction consumes that evidence and
   rechecks the actual connection/header/history. It accepts every newly accepted
   page and root in one batch, records complete object edges and membership,
   advances the retained frontier from its acceptance-time value, and performs
   the existing transactional dependency wakeups. It reads one encoded page
   buffer at a time rather than retaining a second array of sealed pages.
6. Normal catch-up advances across this retention-only batch with the same note
   values, view epoch and authoring context. An `AcceptedSnapshotReceipt` reports
   the committed root, page set and acceptance sequence. Saved-edit receipts and
   snapshot receipts have separate types and consumers.

Root edges name the exact tree plus directly referenced history/bootstrap
objects. Index-page edges name their children; data pages have no object parents.
History objects keep their complete existing dependency edges. Object retention
and the snapshot's represented operation ancestry remain distinct: acceptance of
an older snapshot neither removes newer retained work nor replaces newer Current.
Already accepted exact objects allocate no duplicate acceptance batch or logical
action. A root accepted concurrently by ready processing reports its original
committed sequence.

Both provider profiles retain encrypted private database pages and the existing
database-key derivations. Wire encodings, schema tables, host settings and normal
saved-generation acknowledgment remain unchanged. One ephemeral connection UUID
checks applicability even when a separate copied store has identical IDs and
history counters.

## Retry, cancellation and reopening

`SnapshotCommitHandle` is owner-issued access to the frozen capture and its
construction actor. `retry(snapshot:)` checks the actual session and owned
operation. Construction repeats deterministic emission positions, reusing and
checking already retained exact envelopes. At most one interrupted sealed
emission buffer is held by the construction actor; it is reused verbatim, including
after ambiguous storage or callback failure. A completed root resumes acceptance
directly. This bounds encoded-emission buffering; decoded capture and preview
metadata still scale with their represented state.

Cancellation returns a pending handle and retains admitted inputs. Ordinary
saving remains available while snapshot construction is pending or suspended.
`quiesce()` drains required saved/received work and closes even with unfinished
optional snapshot work. It releases the optional reservation while preserving
retained candidates and accepted objects. Construction stops at its next emission
or database turn; a late completed acceptance reports only its actual committed
coverage. Candidate cleanup remains a separate future owned operation.

A fresh process receives only normal selection/unlock inputs. Existing journal
recovery determines actual committed membership. A retained complete optional root
resumes through durable ready work and semantic checking after checked host
publication; required prerequisites are selected during open. Incomplete page-only work stays
candidate data. Missing callbacks cannot erase committed membership. A
snapshot-only catch-up failure leaves accepted history intact for later catch-up.
Required accepted-page damage follows the existing durable history-damage path
and blocks editable publication. Optional authentic-but-wrong candidates are
retained and specifically rejected while unrelated valid work proceeds.

This is reopening after snapshot acceptance, **not** recovery using the snapshot
to replace damaged current rows. Exceptional rebuilding still starts from the
complete initial bootstrap and applies normal accepted-history catch-up; S4
implements the general-snapshot recovery alternative.

## Executable safety checks

`SnapshotAcceptanceTests.swift` supplies independent values/counts and actual SQL
observations, with both public and encrypted provider profiles:

| Difficult transition | Required observation |
| --- | --- |
| One-page and cross-page snapshots after a saved edit | Exact root/page bytes, complete dependencies and expanded pin; unchanged cells, authoring context, epoch and logical action/operation counts after reopening. |
| Ordinary save while candidate emission or post-commit result is held | New saved contents and retained objects survive; the older snapshot keeps its original cut. A later host generation rejects stale prepared publication. |
| Failure after page retention, root retention or acceptance commit | The same handle retries exact envelopes; one complete batch is accepted and duplicate acceptance is idempotent. |
| Cancellation after retaining a page | Candidate remains owned, subsequent ordinary saving works, and retry completes without replacing the newer note. |
| Close with pending/suspended optional construction or a held committed result | Durable close proceeds, retained bytes survive reopening, unfinished construction stops and a late accepted result reports its real historical commit. |
| Wrong store, copied store with equal identifiers/counters, or reopened owner | Actual admission/evidence consumers reject incompatible capture, retry or connection evidence. A same-owner companion succeeds. |
| Complete root retained before interrupted acceptance | Fresh reopening retains its exact candidates; checked host publication starts optional ready processing and acceptance without redelivery. |
| Authentic wrong body versus valid candidate | Wrong claims are retained/rejected with the precise reason; accepted history and unrelated progress survive. |
| Corrupted required accepted page | Damage is detected and persisted; current publication and reopening remain blocked. |

Existing general-snapshot tests now also durably accept/reopen real snapshots
covering empty collections, edits, Deletes, fresh-birth Restore, causal Undo,
copied-source dispositions and deterministic retirement. Existing malformed-claim
tests remain intact. Durable older-cut cases additionally preserve an already
accepted conflicting branch and a complete repackaged object containing a later
action outside the snapshot's operation cut, including after reopening.

`test-storage-snapshot-process.py` exercises 22 fresh-process scenarios: normal
commit; termination after page/root retention, before/after acceptance commit,
and during/after catch-up; candidate ENOSPC/EIO; acceptance EIO; and ambiguous
sync completion, for both profiles. Root-ready recovery includes another
termination during recovery before successful reopening. Parent expectations are
kept out of the recovery child.

The independent Node inspector decodes actual general root/data/index bytes,
verifies complete ranges, framing/order/counts and the state-stream digest,
resolves exact references, derives complete dependency edges and the retained
frontier, and checks complete operation/action cuts. The process test independently
expects both note bodies, five unchanged operations, three unchanged actions and
the preserved authoring context. Runtime receipts are not its oracle.

Compiler challenges cover private capture, checked-batch, commit-handle and
snapshot-receipt issuance, same-module access, decoding attempts and the saved-edit
consumer's refusal to consume a snapshot receipt. Targeted mutations challenge
missing history/tree edges, omitted capture ownership, wrong connection evidence,
omitted ready-root recovery and an optional-work close gate; each requires its
designated runtime assertion.

## Qualification entrypoints and boundaries

```sh
make -C tests run-swift-storage
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release'
python3 tools/test-storage-snapshot-process.py --binary NVStorage/.build/debug/NVStorageProbe
python3 tools/test-storage-runtime-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-runtime-mutations.py \
  --only snapshot-acceptance-missing-history-edges \
  --only snapshot-acceptance-missing-tree-edges \
  --only snapshot-capture-wrong-owner \
  --only snapshot-acceptance-wrong-connection \
  --only snapshot-ready-recovery-omitted \
  --only snapshot-optional-work-blocks-close
```

The existing `test-storage-phase2.py` qualification driver requires discovery of
all nine new runtime functions and invokes the new child-process campaign,
alongside existing history/connected-lifecycle, schema, independent fixture and
language-boundary checks. Process termination, injected I/O uncertainty and later
corruption remain separate fault classes.

The unchanged `SQLiteFastStartSafety` regression checks acceptance/current-row
ordering, damage exclusion and final publication guards. Its five negative
controls and three reachability witnesses remain required. It abstracts already
validated input and does not model new snapshot framing, candidate installation
or the future all-branch snapshot-based rebuilding algorithm. The new executable
checks qualify part of that abstract input/transaction boundary; they do not
establish arbitrary-history refinement or physical power-loss durability.

The unchanged `SQLiteCollectionSafety` commit scenario separately checks the
existing atomic batch/receipt/recovery mapping. These regressions preserve their
abstract input assumptions; new snapshot semantics are exercised by the concrete
byte, SQL and lifecycle checks above.

## Observed results

Primary host: arm64 macOS 26.6.2, Apple Swift 6.4
(`swiftlang-6.4.0.34.1`). These are executed bounded checks, not release/platform
or physical power-loss qualification.

| Check | Observed result / retained artifacts |
| --- | --- |
| Final full debug suite | 186 functions passed in 97.171 s; `/tmp/nv-phase4-s1-debug-final.log`. |
| Final full optimized suite | 186 functions passed in 69.271 s; `swift.log` under the final qualification directory below. |
| Final optimized qualification driver | All 29 commands passed, including 60 connected cross-store lifecycle schedules, eight generated schedules, 18 rejection schedules and independent byte/SQL checks; all nine required new test functions were discovered. `/tmp/nv-phase4-s1-release-final.log`. |
| New fresh-process snapshot campaign | 22 scenarios passed for both profiles in debug and optimized runs, including second failure during root-ready recovery. |
| Instrumented SQLCipher | Deliberate library-internal use-after-free detected; valid companion and all nine snapshot runtime functions passed in 41.731 s. `/tmp/nv-phase4-s1-sanitizers-final.log`; `nv-cipher-sanitizer-pn86x47x/runtime.log` under the host's temporary directory. |
| Targeted new mutation controls | All six caught at their designated expectation: history edges, tree edges, capture ownership, live connection, ready-root recovery and optional-work close gate. `/tmp/nv-phase4-s1-mutations.log`, `/tmp/nv-phase4-s1-connection-mutation2.log`, `/tmp/nv-phase4-s1-close-mutation.log`. |
| Schema regression | All 17 cases passed; canonical and Runtime DDL remain equal. |
| Compiler boundaries | All 105 ordinary/same-module probes passed against both debug and optimized modules. |
| Existing TLA+ regressions | `SQLiteFastStartSafety`: 1,015-state safety run plus all five negative controls and three witnesses. `SQLiteCollectionSafety` commit scenario: 1,486-state safety run. `/tmp/nv-phase4-s1-tla.log`, `/tmp/nv-phase4-s1-commit-tla.log`. |
| Legacy app build | `build.sh` exposed the existing Xcode 27 deployment-target diagnostic. The equivalent unsigned install passed with `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO`, retaining macOS 11.5; `/tmp/nv-phase4-s1-app-build-override.log`. |

The final optimized qualification driver uses
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-storage-phase2-8jym67iz`.
Its command-by-command logs and completed `results.json` record the broad
fresh-process, generated-fault, rejection, language, independent-fixture and
strict C-boundary checks. The earlier complete driver pass is retained separately
at `nv-storage-phase2-_bl_qcvk` in the same temporary parent; it predates the final
optional-close correction.

## Review corrections

The initial S1 implementation reused the required-save shutdown gate for optional
snapshot work. Review against Protocol's durable-quit rule corrected that mapping:
closing preserves candidate bytes and stops optional construction at a later
emission/database turn. The close test reopens a fresh owner and saves a new edit
before releasing the old operation's held completion. The new edit survives both
an unfinished construction result and a historical accepted receipt.

The copied-store mutation initially used the line inside an asynchronous
expectation body rather than the macro's report line. The assertion is now
single-line and its exact report location remains required; the rerun caught the
intended wrong-connection failure. Neither correction weakens a semantic or
compiler-enforced storage condition.

S2–S4, candidate cleanup, long-history construction/work budgets, additional
platform qualification, physical power loss, provider/UI integration and
backup/salvage/activation remain separately gated work.
