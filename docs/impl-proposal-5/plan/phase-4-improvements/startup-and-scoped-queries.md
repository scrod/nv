# Faster startup and scoped Undo/conflict queries

Status: implemented and qualified within the portable Runtime boundaries,
2026-10-08. The [validation report](startup-and-scoped-queries-validation.md)
records executed checks, measurements and remaining qualification limits.

## A. Publish before independent optional snapshots

Returning open completes verification obligations, required-history checks,
reconstruction, ready Changes and their discovered prerequisites, and indexed
materialization catch-up before capturing editable current rows. Independent
snapshot assembly/verification stays in the durable receive queue. Required
selection is independent of queue order.

A successful checked `publish` reserves the existing receive state before
launching one session-owned drain. Existing receive ownership coalesces repeated
publication. The worker uses existing bounded database turns and save-settlement
notifications. Close stops optional preparation; transient failure leaves exact
bytes and ready/wait/verification records available for explicit retry or reopen.

Qualification holds optional preparation across actual publication, places
required work behind it, and exercises finite saves, receive contention, close,
restart, and failed rejection writes. Bootstrap, reconstruction, unfinished
verification and required damage remain blocking companions. A small scheduling
model checks publication safety, ownership, durable work and finite-interference
progress, with targeted mutations and reachable contested states.

## B. Select exact history before decoding

Capture checked current rows and their accepted prefix. Indexed note-scope action
selection supplies the existing Undo/Redo selector. Conflict reads select current
heads and represented revisions, plus all conflict-copy actions needed by the
public collection-wide disposition result. Collection queries and compensation
commands retain their full-history path.

One shared checked reader groups occurrences by envelope, decodes each once per
query and checks exact IDs, occurrence addresses, indexed links and complete
action membership. Privately issued immutable query evidence carries store,
connection, prefix and scope. Complete `RetainedGraph` evidence keeps its existing
stronger closure requirements. Interrupted verification retains the existing
conservative replay recipe.

Add one derived partial action index for conflict copies in the new private
schema version; older development stores receive explicit incompatible outcomes
without a returning-startup index build. Public result shapes and record encodings
remain unchanged.

Qualification compares selected and full reads with independent expected values,
IDs and dispositions; challenges missing occurrences, links and context; covers
native/portable compensation, branching, multi-note actions, deleted notes,
automatic/derived conflict values and reciprocal copies. Grow unrelated history
through 64, 256 and 1,024 actions: untouched-note/no-copy queries read zero history
envelopes, and each selected envelope decodes once. Global copy work may grow with
copy history. Include connected snapshot/query/save/reopen scenarios, compiler
construction/consumer checks and named mutation failures.

## Boundaries and completion

Reuse actors, workers, queues and indexes. Add no semantic table, sidecar,
long-lived query cache or duplicate history store. Keep snapshot-to-snapshot
retention coverage and pruning separate. Replace REVIEW-START-2 and
REVIEW-HISTORY-1 only after production witnesses and companions pass. Keep
REVIEW-START-3 tracked. Run debug/optimized checks and available platform probes;
report physical power-loss and unavailable platform qualification separately.
