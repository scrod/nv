# Phase 2: private runtime and fresh-process recovery

Date: 2026-09-14. This records the first production-path implementation, not
application integration, a complete proposal-5 reducer, or physical power-loss
certification. The [first-save contract](first-save-reopen-contract.md),
[conformance strategy](swift-storage-conformance-testing-strategy.md),
[LocalStore](../LocalStore.md), specification, ADRs and CONTEXT retain authority.

The subsequent [platform and type audit](phase2-platform-and-type-audit.md) records
actual macOS 11/14 Intel execution, native Ubuntu arm64 Swift/SQLCipher runtime
checks and compiler-diagnostic compatibility, a tightened private
acceptance boundary and the corresponding durability-model update. Results below
remain the original development-Mac campaign unless that follow-up is cited.

The later [zstd codec qualification](zstd-codec-validation.md) replaces the
unreleased zlib envelope format, updates both compiler diagnostic expectations,
and records fresh codec/runtime evidence. Earlier counts below remain dated runs.

## Implemented path

| Responsibility | Implementation |
| --- | --- |
| Frozen bootstrap, real Genesis/Imports/ImportComplete/descriptor/pages/root | `InitialCollectionV1`, existing `InitialBootstrapValidationV1` |
| Physical private-directory ownership | `CStorageIO`, directory flock plus held directory/database identities and repeated validation |
| Blocking work and connection lifetime | `DatabaseLane`; one serial Dispatch queue, private connection state, no Sendable database handle |
| SQLCipher boundary | `Database`; pinned 4.19.0 revision `c4b275a47932888216bade83aff2bbc73df0ff85`, runtime cipher-version verification |
| Exact acceptance and retention | `HistoryDatabase`; exact envelopes, descriptor retention, operation/action occurrences and distinct edges, one batch sequence, maximal object frontier, durable wakeups in one transaction |
| Ordinary writer-history checks | `OrdinaryHistoryV1`; complete groups, exact before/after, causal basis, note predecessors, all same-scope maxima and observed same-origin predecessor |
| Materialization and returning launch | `OrdinaryDatabase`, `LocalStore`; separate guarded current-row transaction, indexed accepted suffix, ready-work draining and coherent capture |
| Captures, retry and acknowledgment | `Commit`; immutable captures, reserved in-flight slot, one sealing per captured attempt, exact-identity recovery lookup and restricted receipt construction |
| Host generation checks | `HeadlessModel`, `Publication`; matching pending-generation clearing and final store/session/view/host-generation publication checks |

New candidates alone receive DDL. Existing incomplete, incompatible or damaged
stores return explicit errors. Empty settings have a separately versioned record;
unknown settings are preserved and rejected. Missing required settings/bootstrap
or known required history never becomes an editable empty collection. Invalid
derived cells/context can rebuild from retained bootstrap plus the indexed accepted
tail; a rebuild interrupted again remains recoverable. A history acceptance receipt
remains valid if the separate materialization fails; publication requires catch-up.

Returning launch reads current rows, the current authoring context, required header
and pin leaves, and indexed pending work. It does not authenticate every old BLOB.
Known required loss is a recovery failure; otherwise unread ancestor damage is
detected when that evidence is accessed. This avoids claiming detection of arbitrary
historical corruption without reading it. Authenticated private rows rely on their
validated transactional construction, not a forged-history-proof field in each row.

The connection verifies WAL, FULL synchronous, foreign keys, memory-only temp storage,
disabled mmap and macOS fullfsync/checkpoint_fullfsync. Automatic WAL checkpoints
and checkpoint-on-close are disabled. Explicit maintenance/quiesce can checkpoint;
its success is not part of a save receipt. Both profiles use encrypted private
pages and the already specified database-key derivations. Password-free recovery
uses no device secret. Writer allocation rolls to a fresh epoch at the encryption
usage limit or sequence exhaustion; retries retain their original envelope.

This native owner is for the private candidate directory. It refuses symlink leaves,
database hard links and observed directory/database replacement. A private-path move
requires fresh selection/reopen; it is not the provider root-move adapter. Advisory
ownership coordinates cooperating NV owners and does not exclude arbitrary programs
that ignore it. No SQLite identifier, key or stored header substitutes for the lease.

## Frozen private record layouts

These are the raw correctness-baseline codec, not a packed startup cache. All
integers use the first-save contract's big-endian scalar rules. All decoders check
length/count bounds before allocation, canonical ordering, complete consumption,
and the 64-MiB enclosing-record ceiling. Later larger/paged frontier representations
need their own codec; this development ceiling cannot become a collection-lifetime
limit or permission to discard history.

| Record | Exact layout |
| --- | --- |
| Stored operation occurrence | full `SegmentLocator` (56 bytes), `u32(index)`, operation ID (32): 92 bytes |
| Stored action occurrence | full `SegmentLocator` (56), `u32(index)`, action ID (16): 76 bytes |
| `CurrentNoteCellV1` | `NVCEL1\r\n`, `u16(1)`, birth16, `bytes(NoteValueV1)`, represented operation occurrence, `vector(stored action occurrence)` for the note scope |
| `AuthoringContextV1` | `NVCTX1\r\n`, `u16(1)`, `vector(stored operation occurrence)` for the global operation maxima, `vector(stored action occurrence)` for collection-scope maxima |
| `private_groups` bootstrap | key is exact UTF-8 `bootstrap`; positive generation; codec1; payload is the exact 56-byte initial snapshot-root locator |
| `private_groups` empty settings | key is exact UTF-8 `settings`; positive independent generation; codec1; payload is zero bytes |
| `private_groups` known history damage | optional exact UTF-8 key `history-damage`; generation1; codec1; zero-byte payload. Presence blocks ordinary reopen until validated repair. Invalid incoming bytes cannot create it. |

Occurrence vectors sort strictly by expanded operation/action ID and reject
duplicates. The current cell's represented revision is also its ordinary Put
predecessor. Note-scope action maxima are distinct from collection-scope maxima;
neither uses acceptance sequence as causal order. Total cell size is
`126 + encodedNoteValueSize + 76 * actionCount`; context size is
`18 + 92 * operationCount + 76 * actionCount`.

`Fixtures/current-state.json` is independently reconstructed by
`tools/check-current-state-fixtures.py`: one 234-byte cell and one 186-byte context,
with exact scalar/reference fields, plus Swift truncation/noncanonical tests.
The resource DDL must byte-match `sqlite-local-schema.sql`; the driver checks it.

## Executable evidence

Run through the existing driver:

```sh
bash tools/build-storage-deps.sh
make -C tests run-swift-storage-phase2
make -C tests run-swift-storage-phase2 SWIFT_STORAGE_PHASE2_FLAGS='--configuration release --mutations'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--sanitize address -Xswiftc -strict-memory-safety'
```

The driver requires actual named Swift Testing discovery and an all-passed summary;
the XCTest compatibility runner's zero-test summary is not success evidence.
It runs real Swift tests, fresh processes, ordinary/same-module compiler clients,
independent fixtures, SQL schema tests and strict C compilation. Optional mutation
campaigns build isolated baselines and source mutants rather than reuse a workspace
test executable. Temporary artifact directories contain commands, logs and reports;
the source tools reproduce results after those temporary files expire.

### Results on the development Mac

Final source checks used Swift 6.3.3, arm64, macOS 26.6.2 (25G83), and the pinned
CommonCrypto SQLCipher build. Counts below are discovered test functions or named
process scenarios, not a count of all parameter combinations or all possible states.

| Check | Result |
| --- | --- |
| Native Swift suites | 70 functions passed in debug and optimized builds |
| Fresh-process campaign | 70 named checks passed in each build; both profiles; includes eight cold batches of 16 independent create/reopen pairs |
| Independent startup query check | 762 → 786 SQL VM steps after adding 160 unrelated historical objects, with the same two current notes, in both profiles |
| Compiler clients | 21 Core and 20 Runtime ordinary/same-module cases passed, plus diagnostic-classifier controls |
| Canonical fixtures | All six fixture/crypto inspector entrypoints passed |
| Schema | Resource DDL exact-byte equality and 17 direct SQL tests passed |
| Mutation campaigns | Seven bootstrap and eight Runtime mutations produced their intended failures in debug and optimized builds; both valid baselines passed |
| Cold-init dependency experiment | Delayed extra-init negative and completed-init valid companion both matched their exact expected return codes |
| AddressSanitizer | All 70 functions passed with optimized code and strict-memory diagnostics enabled |
| ThreadSanitizer | All 15 Runtime functions, including parameterized schedules, passed |
| Native C diagnostics | Owner, VFS/completion layer and cold-init probe passed strict C warnings-as-errors checks |
| Legacy boundaries | `build.sh` and `test-epoch4-v5-compatibility.sh` passed; no app/UI integration added |

Final full-driver artifacts are `nv-storage-phase2-5y31jp0k` (debug) and
`nv-storage-phase2-qifnqv9z` (optimized), under the system temporary directory.
The completed mutation campaigns are recorded by `nv-storage-phase2-axsdk9ze`
(debug) and `nv-storage-phase2-bavo8hok` (optimized). Their earlier process stage
had 68 cases; the final 70-case stage adds the post-COMMIT ownership-loss cases.
Both mutation builds contain the final ownership fence and PRAGMA checks. Sanitizer logs are
`/tmp/nv-storage-phase2-qualified-address.log` and
`/tmp/nv-storage-phase2-qualified-thread.log`. Temporary artifacts are diagnostic
evidence, not required recovery input or permanent repository dependencies.

The process campaign covers both profiles, two independently expected initial notes,
partial bootstrap, ordinary saves, commit-without-callback, interrupted current-row
installation and repeated-crash rebuild. The opener receives only surviving files
and normal selection/unlock inputs. An independent Node/OpenSSL inspector decrypts
and hashes exact retained envelopes, parses operations/actions/snapshots, verifies
SQL membership/edges, compares the pin's maximal closure and checks current references.
It bypasses Runtime's receipt flags and materializer. Source note expectations stay
in the parent test process.

Fault classes remain separate:

- Process termination before/after real COMMIT and within materialization/rebuild.
- EIO, ENOSPC and WAL writer-lock busy injected beneath the actual SQLCipher engine,
  including an error after the underlying sync returned. Pending captures remain
  owned, quiesce refuses to discard them, and retry queries exact committed identities.
- A test-only COMMIT-completion barrier holds the actual worker while the waiting
  task is canceled and a newer host Edit/Delete becomes pending. A second persist
  cannot enter. Releasing the barrier preserves the old durable history and the newer
  host generation; quiesce drains the admitted work.
- Simulated loss truncates only a checked uncommitted WAL tail after an explicit
  baseline checkpoint. This is a selected persistence-loss image, not physical
  power-loss certification or deletion of acknowledged frames.
- Later required-state/history damage is refused; derived-only damage rebuilds while
  preserving exact retained objects and private settings.

Swift schedules deliver a child before multiple prerequisites in all six delivery
orders, reopening between deliveries. They compare exact missing prerequisites,
accepted membership, final values and frontiers. Duplicate envelopes are idempotent;
repackaged equivalent operations gain retention without repeated logical effects.
Wrong-store/session/view/host-generation evidence reaches real consumers. An older
settings update after new acceptance cannot regress retention. Semantic negatives
have valid companions: wrong before-state, omitted scope maximum and an intermediate
member falsely named as the final after-state. Concurrent received history is validated
against its writer's basis, retained, and explicitly requires the later reducer rather
than producing a partially editable view.

The eight Runtime mutations target early acknowledgment, omitted dependencies,
regressed retention, stale completion, missed wakeup, skipped store/session checks,
skipped host-generation checks and wrong current materialization. Each requires its
intended assertion, correct test discovery and a valid baseline; compilation failures
and unrelated errors receive no credit. The seven existing bootstrap mutations remain
part of the full campaign.

## Audit findings incorporated

1. An empty ready-work query joined and sorted through the historical object table.
   It is now an indexed ready-ID lookup followed by one exact object lookup. The
   startup test adds 160 unrelated accepted objects and bounds SQL VM-step growth;
   it measures a query-plan property, not a universal startup latency guarantee.
2. Bootstrap reconstruction must materialize through the bootstrap's actual acceptance
   batch, then apply the remaining suffix. Assigning the latest batch to bootstrap-only
   rows could lose a committed tail. Tests now cover invalid rows with such a tail.
3. Previous-origin links are provenance edges into observed history, not a global
   latest-origin election. A preserved fork may reference its own predecessor even
   when another branch is observed. Exact origin and dependency checks still apply.
4. Completed captures release Runtime's retained bodies/envelopes. Duplicate logical
   requests query committed identities and exact values; failed/ambiguous work keeps
   its immutable inputs. Returning an old receipt never reapplies an old value.
5. Queue-owned connection storage replaced a Sendable database handle. Strict-memory
   diagnostics identify the remaining opaque-pointer/C-call boundary in `Database`.
   Buffers are copied with SQLITE_TRANSIENT, column buffers copied before stepping,
   statements finalized on all exits, and handles/lease closed on the serial queue.
   The owner shim supplies the only physical lease; IDs cannot substitute for it.
6. Ordinary birth provenance comes from validated Import/Create history, not UUID
   version bits. The subset can delete an ordinary imported version-8 UUID; actual
   deterministic conflict history still requires its later codecs/reducer and complete
   retirement action. A UUID spelling alone cannot select retirement semantics.
7. Parallel cold opens exposed the extra-initialization boundary in the pinned
   SQLCipher build. `sqlite3_initialize()` is documented as thread-safe; this is not
   evidence of general connection non-reentrancy. SQLite's developers separately
   [documented the `SQLITE_EXTRA_INIT` race](https://sqlite.org/forum/info/14183b98fc0b1dea)
   and introduced `SQLITE_EXTRA_INIT_MUTEXED`. SQLCipher's pinned
   [build instructions](https://github.com/sqlcipher/sqlcipher/blob/c4b275a47932888216bade83aff2bbc73df0ff85/README.md)
   require the original extra hook. `tests/SQLCipherColdStartProbe.c` compiles the
   same amalgamation with a test wrapper that pauses that hook without changing
   return values: a concurrent open succeeds but keying returns SQLITE_ERROR;
   after the hook completes, keying and writing succeed. Pausing after actual
   cipher initialization is the valid companion and keying succeeds immediately.
   This establishes a mechanism consistent with the intermittent suite failure;
   the original failure did not record its precise failing call. Runtime now
   completes explicit initialization through Swift's process-wide once initialization
   before any of its collection opens, following SQLite's
   [explicit-initialization recommendation](https://www.sqlite.org/c3ref/initialize.html).
   Independent collection queues remain parallel. The cold-process campaign bypasses
   the VFS installer (which otherwise warms initialization), opens/reopens 16 stores
   together, and repeats in four fresh processes for each profile. Future clients
   using this same SQLCipher image directly must coordinate its initialization and
   must not shut it down beneath Runtime's owners. Keying precedes connection
   configuration, as required by SQLCipher's API ordering.
8. Private ownership must still hold after COMMIT returns. The transaction boundary
   now rechecks the held directory/database identities before reporting success.
   A test moves the synthetic private directory while the actual COMMIT completion
   is held: Runtime returns an owned pending result, keeps the host generation and
   refuses quiesce. Restoring the same directory permits an exact committed-identity
   retry without a second logical edit. This checks private-store loss, not provider
   root loss, which does not by itself block healthy local acceptance.

## Qualification boundaries and next increment

The implementation has now also passed the [platform process campaigns](phase2-platform-and-type-audit.md)
on macOS 11.7.11 and 14.8.9 with an 11.5-targeted executable, and natively on Ubuntu
arm64 with Swift 6.1.3 and SQLCipher/OpenSSL. The Linux optimized process campaign
used ext4; its separate Runtime compiler-probe campaign now passes with the
approved exact alternative diagnostic. The exact macOS 11.5 point release and physical
power failure remain unqualified. AddressSanitizer exercises the Swift/C adapters and vendored
package C code; the separately compiled SQLCipher archive and system crypto are
not fully sanitizer-instrumented. Strict-memory warnings at the reviewed C boundary
are not a claim of compiler-proven memory safety. The two narrowly scoped unchecked
Sendable containers protect Dispatch queue ownership; no evidence constructor or
database handle becomes publicly fabricable.

The C audit uses `-Wall -Wextra -Wconversion -Werror`; clean runtime-only Swift
typechecking uses `-strict-memory-safety`. Remaining warnings concern opaque handle
storage, SQLite's documented transient-destructor sentinel, and bounded pointer
borrows/copies in `Database.swift`. They are reviewed exceptions, not globally
suppressed diagnostics or an added compiler-version requirement. ThreadSanitizer
checks the Runtime schedules; it does not instrument the separately built SQLCipher
archive. Raw database pointers are neither Sendable nor exposed by public APIs.

The runtime has no fixed-nonce production seal entrypoint. Literal fixed-nonce
fixtures are reader vectors; writer tests use fresh nonces and independent crypto
checks. Test VFS/completion controls are separate targets, excluded from the Runtime
product. A complete release dependency/security review remains separate.

This first reducer supports ordinary single-valued histories, empty host settings
and raw current cells. Large-bootstrap/resumable ancestry scheduling, exhaustive
generated fault histories, full receive-quarantine handling, complete later record
layouts and context paging remain
development gates. This is not a shippable reduced-feature provider profile.
The next increment extends the existing two-store byte exchange to general concurrent
Current reduction, deletion/conflict preservation and portable undo. Zstd/private-row
locality qualification follows the adopted candidate. No application UI/search,
provider publication, Apple resolution, final selected-store cutover, packed cache
or automatic VACUUM scheduler is included. The original implementation campaign
did not change modeled transitions; the [follow-up audit](phase2-platform-and-type-audit.md)
updates the retained durability model's private transaction stages and single-writer
rule. Unchanged models remain scenario sources, not certification of this adapter.
