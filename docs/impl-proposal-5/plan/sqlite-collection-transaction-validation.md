# Private SQLite collection: three connected validation cases

Status: current-materialization transaction mapping, rechecked 2026-09-14. Extends the
[SQLite design experiment](sqlite-local-store-experiment.md) and
[SQLCipher qualification](sqlcipher-validation.md). The subsequent
[LocalStore contract](../LocalStore.md) adopts and extends this mapping with
separate current materialization and concrete fast startup. The fixture below
is **not a production Swift adapter**; its historical measurements remain scoped
to the tested schema/actions, not every later contract detail.

The target is one private SQLite database per local collection containing exact
immutable history, required private state and derived current rows. Its SQLite WAL/journal is an internal transaction mechanism, never
NV history transport. `NV Data` retains the existing immutable provider format.
An outside unlock/bootstrap mechanism and local ownership are still needed;
an encrypted database cannot contain its own only usable unlock secret.

## Concrete mapping

| Data | Candidate database role |
| --- | --- |
| Exact immutable object bytes | Immutable BLOB rows keyed by exact object identity. Keep received-but-parked objects distinct from accepted history. |
| Accepted operations and complete actions | Indexed records tying validated history to its complete action/dependency closure. Accept once; duplicate arrivals do not allocate another application batch. |
| Local application sequence | Monotonic sequence assigned transactionally to completed application batches, including later acceptance of old objects. Neither provider order nor causal identity. |
| Required private state | Store/collection association, settings, retained-history evidence, pending references/reservations and receipts. None depends on derived current rows. |
| Dependency/ready indexes | Parent-to-waiting-child indexes and durable acceptance work. A newly satisfied dependency updates this work in the parent's acceptance transaction. |
| Current materialization | Current values/compact continuation data plus scope/version and the exact application prefix used to construct them. No embedded archive of every past body. |
| Pending input BLOBs | One latest retained observation and separately owned frozen operation inputs. Replacement payload and reference switch can share a transaction. |
| Observation/operation links | Durable exact retry identity and later settlement evidence. Finding a live note with a matching UUID is not the lookup. |

Local admission to NV's in-memory model remains distinct from durable completion.
Immediate typing and synchronous search are unchanged. An admitted operation
retains its exact inputs while the local lane commits it; provider/file/UI delays
cannot turn its completed history back into unadmitted work.

### T1: retain or replace pending input

In one transaction insert the bounded immutable pending payload and update its
generation-checked latest reference. Preserve any separate frozen reference.
Rollback leaves the old payload/reference usable. A reservation durably binds
its fresh birth/action/operation identities and exact inputs before admission,
but is **not** replayable consent after a crash.

This replaces the candidate's local payload-file/reference-file installation
gap with an ordinary database transaction. Payload garbage collection still
requires ownership checks; the executable tests do not implement GC.

### T2: accept history

In one transaction retain exact object bytes as needed, validate required
dependencies/complete actions, insert acceptance and the next application
sequence, advance required history evidence, update readiness of waiting children,
and preserve the affected observation's operation link. Commit before durable
acknowledgment, provider publication eligibility or physical completion.

An already-stored object becoming applicable takes a new application sequence;
it does not need new bytes or a second identity. Lost callback/repeated recovery
uses the committed operation, even if a later Edit/Delete made its birth no
longer current. A prepared reservation without complete committed history returns
to revalidation/decision rather than replaying a manual command.
The probe does not persist a redundant “committed” flag: joining the reserved
exact operation identity to actual committed history distinguishes these cases.

Settings updates share the single owner/transaction machinery but are independent
values: neither history acceptance nor materialization overwrites them with
an old copied metadata object. SQLite's single-database atomicity supplies an
old-or-new transaction result, not correctness of NV's reducer or external-file
authority. [SQLite atomic commit](https://sqlite.org/atomiccommit.html).

### T3: advance current materialization

Capture the values **and** represented acceptance prefix consistently. Recheck
the current view generation/prefix, then update complete current rows/context
and their prefix atomically. Do not relabel old values with a newer accepted
sequence or regress a newer materialization. Failure leaves accepted history and
required private state intact. Before editable reopening, apply the indexed
accepted suffix and commit the resulting current materialization.

The probe's three fixture bytes abstract the atomic update of three current
cells, not a packed format or a second acceleration representation. It also
tests invalidation/reconstruction of derived rows. Production uses the row DDL
and generation checks in [LocalStore](../LocalStore.md); independently validated
row/context codecs and reducer semantics remain implementation requirements.

### T4: finish physical association

After history is durable, reacquire the original root/store and exact file
observation. For a fresh import whose source already contains the intended bytes,
verify it without rewriting. Commit the historical receipt and transfer/remove
the old pending link **together**, retaining any newer preview independently.
If the source or root changed, preserve history and defer association. If a
causally later Delete arrived, settle the admitted observation without attaching
the deleted birth; keep a newer unreviewed preview.

A fresh observation number alone cannot retarget an old operation into a replaced
root. Likewise, an old successful receipt is not current authority after restart.
An external edit occurring after a valid observation can make it historical;
SQLite does not lock arbitrary filesystem writers. Actual editor/projection
operations still need the spec's current root/file/generation checks.

## Important correction discovered during validation

**Current rows plus accepted suffix are insufficient by themselves.** A child can have been
stored before materialization, then its missing parent accepted, followed by a crash
before the child is accepted. The first prototype reopened from the accepted
prefix without finishing that now-ready child. That was a gap in the candidate
mapping, not a reason to weaken the spec's startup rule.

The corrected transaction also makes newly ready work durable. Startup drains
that indexed queue with the normal acceptance transaction before completing
editable recovery, then catches up and captures current rows. A crash while
draining merely repeats the same idempotent acceptance. Objects whose required
history is still absent remain parked. No full scan/read of all historical BLOBs
is introduced: normal work follows indexed ready IDs and dependency edges.

The prototype has a one-parent fixture; production needs the equivalent indexes
for complete transitive dependencies, multi-operation action groups, descriptors,
unsupported data and exact accepted frontiers. All startup publication still
runs under the local owner's admission/generation fence. This is not permission
for another database writer to race an unfenced final live-model publication.

## Executable coverage

[C probe](../../../tests/SQLiteCollectionProtocolProbe.c) reuses the existing
fault-counting VFS; [runner](../../../tests/run-sqlite-collection-protocol.py)
uses fresh processes and temporary synthetic files/databases. It runs against
system SQLite or the pinned SQLCipher build, in WAL and DELETE journal modes.
The fixtures exercise:

- Insert object → action/application/private-state commit → kill before/after
  commit or inside VFS write/sync → reopen, checking coherent old/new state.
- Disk-full pending-preview and receipt commits; old references/links remain
  usable, and later retries do not repeat the note operation.
- Parked child before materialization, later parent/ready-queue commit, interrupted child
  acceptance, and a second crash during recovery. Acceptance remains unique.
- Captured current-row reduction installed after another application, interrupted
  materialization rebuilding, missing/foreign-scope derived rows, and an unaffected note/settings. A delayed
  result cannot overwrite an already newer materialization.
  A WAL-only case commits another writer between value and prefix extraction
  inside the read transaction; removing that read transaction is a failing control.
- Exact import input after the external file changes post-admission; an older
  frozen input and newer pending preview survive independently.
- Lost import callback; crash between receipt insertion and pending settlement;
  later Delete and repeated reopening; no live-note-existence shortcut.
- File change, equal-content replacement by a different local inode, logical
  Delete and root-generation invalidation between verification and settlement.
  Repeating an attempt after root replacement still cannot retarget it.
- One combined trace connects a lost Import callback, delayed materialization,
  parent/ready work, later Delete, newer preview and root replacement; crashes
  interrupt both ready acceptance and receipt settlement before current-row reconstruction.

Negative controls deliberately use insertion-order tails, combine old materialized
values with new coverage, skip ready draining/enqueue, replay reservation consent,
drop the operation link, use live-only recovery lookup, or accept stale receipts.
The runner requires each specific semantic mismatch/assertion, not any crash.

These are **not** production persistence-format tests. A synthetic object is one
complete known action, bodies/IDs are small fixture values, and the three-byte
view abstracts three synthetic current cells, not a production encoding. File checks exercise exact fixture bytes and
scoped stat evidence, not an Apple/File Provider identity theorem. Root replacement
is an explicit generation intervention. No xattr, existing-file overwrite, Apple
version setter, real user note, power failure, or real multi-Mac provider is used.
The receipt flag records historical association, never a recovered live accessor.
Pending snapshot GC and general repeat-scan classification remain integration work.
The probe builds its tiny materialization by replaying the fixture and runs whole-table
diagnostic assertions at reopen. These are test oracles, **not** proposed startup
work. Production must obtain the current rows from a verified captured reduction or
transactionally maintained current values; the healthy startup path must use
indexed uncovered applications/ready work, not scan all accepted history.

## TLA+ coverage and boundaries

[SQLiteCollectionSafety](../../tla/SQLiteCollectionSafety.tla) connects the same
four transaction roles. Separate cases cover commit/recovery, parked acceptance,
and import/association; a larger combined case composes them. Transactions have
uncommitted object/action/application stages, followed by atomic commit or abort;
two crashes can interrupt execution/recovery. Rejected stale materializations
release their capture so a fresh attempt remains possible. Materialization capture/installation,
source/root changes, preview retention, receipt settlement, acknowledgment and
independently ordered peer delivery/application are separate actions.

Assertions cover complete transaction state, dependency closure, exact ready work,
acknowledged recoverability, materialization-prefix truth, exact reopen values, required
input/link ownership, fresh receipt activation, no replayed consent/duplicate
import, monotonic history and peer results. The fixed graph has independent
expected-value assertions, not just equality between two uses of the same reducer.
Controls break these rules; witnesses establish lost-callback recovery, parked
acceptance, deleted-import settlement after two reopens, separate latest/frozen
ownership, and Delete reaching a peer before its prerequisite Import.

No fairness, state/depth constraints, symmetry or `VIEW` suppression is used.
Unused transaction/capture scratch is cleared when its operation ends; this
reduces accidental state multiplication without removing a live protocol step.
Recovery diagnostics are also cleared after a subsequent commit/crash; assertions
inspect the actual reopen transition, not a stale diagnostic. The combined case
collapses remote acceptance's invisible uncommitted writes into one SQL commit;
its Import still has every staged write. Remote acceptance neither observes the
file nor acknowledges work before commit, so an interrupted remote transaction
has the same pre/post durable outcomes. Focused cases and compiled parent/child
crash cuts check those expanded transactions separately. Recovery atomically catches up current rows before editable publication. This is an explicit
atomicity abstraction, not a new assertion that SQLite commits physical files.
Finite safety is not unbounded proof or unconditional convergence. SQLite's
all-or-nothing commit and validated complete objects are model assumptions tested
separately by compiled experiments; peer storage is abstract and has no peer
crash. General causal merge/compensation remains in the existing models.

The [external recovery bridge](../../tla/ExternalRecoveryBridge.tla) remains the
reference for content-changing/neutral associations and concurrent Delete/edit;
the [projection bridge](../../tla/ProjectionRecoveryBridge.tla) covers safe writes,
source accounting and pending output generations. Neither is replaced or silently
claimed as a formal `INSTANCE` refinement by this narrower SQLite model.

## Executed results — 2026-09-14

On Apple Silicon/macOS 26.6.2, both system SQLite 3.51.0 and the previously qualified
SQLCipher 4.19.0/CommonCrypto build completed **113 checked observations and 17
designated mutation runs per engine**. Counts include both journal modes and
repeated reopens, not 113 independent protocol properties. The combined trace
finishes with the Import still present in history, its birth deleted, the formerly
parked child represented, the newer preview retained, the frozen input released,
and no stale physical association. The WAL concurrent-reader test also rejects
extracting values and their coverage in separate read snapshots.

Retained executable artifacts (`results.json` and `calls.jsonl`) are under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`:

- System SQLite: `nv-sqlite-protocol-is0enbtf`.
- SQLCipher raw-key variation: `nv-sqlite-protocol-uh_cbgmz`.

All **21 TLA+ checks** completed with the documented final abstraction: four
exhaustive safety scenarios, twelve designated counterexamples and five witnesses.

| Safe scenario | Distinct states | Seconds |
| --- | ---: | ---: |
| Commit/crash/reopen | 1,486 | 2.66 |
| Parked acceptance / materialization boundary | 1,125 | 1.95 |
| Import / association / later Delete | 101,404 | 19.01 |
| Combined | 4,884,374 | 431.61 |

TLC artifacts are in `nv-segment-tlc-22k_83uf` under the same temporary parent;
each case includes its module, generated configuration and `tlc.log`. The combined
case uses 4 GiB heap/four workers; focused cases use 1 GiB/two workers. The runner
no longer evaluates every component of `Safety` a second time as individual
invariants: the conjunction still contains all of them, and all action properties
remain checked. No state/depth constraint or scenario reduction was introduced.

Earlier 180/600-second combined runs did not finish and are not passing evidence.
An intermediate run was stopped when review added explicit rejection/release of a
stale materialization capture. The final model retains the original two-crash
budget and remote-SQL atomicity abstraction, commits caught-up current rows before
reopening, and permits fresh work after rejecting a stale result. Its source
matches the result above. Timeouts and interrupted runs are never counted as passes.

### Reproduce

```sh
python3 tests/run-sqlite-collection-protocol.py
python3 tests/run-sqlite-collection-protocol.py --sqlcipher-build /path/to/sqlcipher
python3 docs/tla/check-segment-models.py --java /path/to/java \
  --jar /path/to/tla2tools.jar --only sqlite-collection --timeout 900
```

Use the [SQLCipher build recipe](sqlcipher-validation.md#reproduction-and-evidence)
for its optional raw-key variation. Keys/data are deliberately public fixtures.
The tested TLC build reports `2026.09.12.025210`, revision `867aefb`; its jar
SHA-256 is `db131ddb48e7004d823bef4493df7b35694babe37505b9d9fa5685e7a331f1f1`.
Java is the bundled Wolfram Engine ARM runtime. Runners
retain JSON outcomes, generated configs and logs in their printed temporary
directories. No app source changed; unchanged AppKit/TLA families are not rebuilt.

## Adoption boundary

The semantic sources remain [Protocol](../Protocol.md#pending-file-commit-and-recovery-records),
[DUR-01/START-01/IMPORT-01](../../iCloud-Drive-Support-Spec.md),
[ADR 0004](../../adr/0004-make-local-history-durable-before-external-effects.md),
[ADR 0005](../../adr/0005-separate-startup-cache-private-state-and-visible-history.md)
and [the glossary](../../../CONTEXT.md). Their adopted physical mapping is [LocalStore](../LocalStore.md): the private database uses atomic transactions; provider/projection filesystem barriers remain separate. No packed startup format survives this mapping. These tests do not complete the production adapter or alter provider/undo policy.
