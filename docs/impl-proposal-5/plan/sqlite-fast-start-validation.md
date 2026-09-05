# Private SQLite current-row startup validation

Date: 2026-09-14. Contract: [LocalStore](../LocalStore.md).
The packed startup cache is removed; immutable provider snapshots are unchanged.
These are SQL-mapping and bounded design tests, not the production Swift runtime.

## Executable SQL checks

Run `python3 tests/run-sqlite-fast-start-contract.py`. It executes the
[implementation DDL](sqlite-local-schema.sql), using synthetic cells containing
both body and authoring context. No alternate cache schema or JSON packing remains.

**21 named checks pass** on SQLite 3.53.4: acceptance surviving materialization
rollback/reopen; deletion and body-equal context catch-up; fresh-birth restoration;
stale final publication; a changed view epoch at an identical prefix; a concurrent
writer during a multi-query read transaction; multi-parent ready-work recovery
and duplicate delivery. Four mutation controls omit deletion/context updates or
skip prefix/epoch publication checks and expose the corresponding wrong results.

With 10,000 additional historical BLOB rows, a SQLite authorizer forbids reads of
old BLOBs and fixture operation rows during healthy current-row capture. The
accepted-suffix query uses an indexed range search. This checks query boundaries,
not disk latency, arbitrary reducer complexity or zero journal-recovery cost.
The added table-order query-plan check rejects UUID-index traversal or a temporary
sort for full startup capture. The [aged clean-exit benchmark](aged-current-row-startup-validation.md)
separately measures physical locality and allocation lifetimes; these do not
change a modeled transition or require rerunning the unchanged TLA+ configurations.
Rollback/reopen here are not process-kill or power-loss tests; the
[compiled transaction probes](sqlite-collection-transaction-validation.md) exercise
separate child-process and VFS failures.

## Bounded TLA+ checks

```sh
python3 docs/tla/check-segment-models.py --java /path/to/java \
  --jar /path/to/tla2tools.jar --only sqlite-fast-start --timeout 180
```

[SQLiteFastStartSafety](../../tla/SQLiteFastStartSafety.tla) separates acceptance,
atomic materialization, startup capture/publication, a rebuild epoch, known damage
and one crash/reopen. Three batches create two notes, delete one and update only
the other's authoring context. Independently enumerated expected values check the
incremental update implementation. No fairness, state/depth constraint, symmetry
or `VIEW` suppression is used.

All **nine configurations** completed: one exhaustive safety case (**1,015 states**),
five designated mutation counterexamples (missing deletion/context updates,
stale prefix/epoch publication, ignored known damage), and three reachability
witnesses (complete delete/context catch-up, crash/reopen, recapture after rejecting
stale work). Witness counterexamples prove reachability, not unconditional progress.
All retained acceptance survives modeled crashes. An initial syntax error was
corrected and is not counted as a test result.

Results/configurations/logs:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-segment-tlc-4bpq9ra1`.
TLC build 2026.09.12.025210, revision 867aefb.

## Removed and retained obligations

Cache encoding/source certificates, branch-binding batch tokens, delta logging/
pruning and cache-worker publication are no longer modeled or specified. Their
deletion/context and stale-result obligations now apply directly to current rows.

Production still needs independently validated current-cell/authoring-context
codecs; complete acceptance/index/pin/ready transactions; exact reducer results;
owner/lifecycle/view-generation fences; and SQLCipher/VFS/credential/repair
qualification. Invalid derived rows require reconstruction; required/shared DB
damage is not silently ignored. Page authentication and SQL atomicity do not prove
reducer semantics. Healthy startup reuses validated private-store continuity; it
does not detect unread corruption or rollback of all independent evidence.
