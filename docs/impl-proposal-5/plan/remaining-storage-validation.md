# Remaining storage work: decisions and executable evidence

Date: 2026-09-14. This tracks the five requested completion areas. It distinguishes
implemented codecs, isolated platform evidence and production-adapter gates.
It does not certify the complete history engine. The subsequent
[Phase 2 report](phase2-local-runtime-validation.md) records the now-implemented
ordinary local Runtime and supersedes earlier next-step statements about that slice.

## Completion status

| Requested area | Completed in this increment | Still outstanding |
| --- | --- | --- |
| Record encodings | First-subset action/payload, public/encrypted envelope, descriptor/KDF, initial snapshot, selection-record and recovery-key codecs; independent expected bytes; connected initial-import semantic validation | Later compensation/conflict/derived-state/projection/general-snapshot/private record layouts and fixtures; general Current/history semantics |
| Limits | Exact object/descriptor/stamp/password ceilings and concrete resumable worker/retry budgets; full-layout and full-search measurements | Runtime scheduling enforcement and actual admission-path size checks |
| Recovery details | Exact selected-record/recovery-key encoding and typo/damage rejection; source-preserving activation ordering | Production Foundation selected-store activation and its crash/failure integration; complete private-state codecs |
| Startup cache | Equivalent indexed-row/packed benchmarks; packed cache removed; [aged layout](aged-current-row-startup-validation.md) and [non-rewriting clean-quit candidate](clean-quit-locality-strategy.md) measured | Qualify compressed current cells/page geometry and optional bounded read-ahead in the actual adapter; cross-platform, lifecycle/failure and whole-store performance gates remain; no universal packed-equivalence claim |
| Native external undo | Registered public editing-protocol probes on both available macOS versions | Actual NV causal router, shared-view bridge and real IME qualification; no fallback adopted |

Thus the five-item request is **not completely implemented**. In particular,
passing codecs/SQL constraints do not close the later-format and activation
gates. No unimplemented record is silently enabled or declared semantically valid.

## Initial-bootstrap validation

The next prerequisite is now executable in
[`InitialBootstrapValidationV1`](../../../NVStorage/Sources/NVStorageCore/InitialBootstrapValidationV1.swift).
It connects selected collection/key/profile, actual authenticated envelopes,
exact locator/index references, the complete initial operation/action closure,
Genesis/ImportComplete count/value commitment and all snapshot rows. Duplicate
semantic claims count once; conflicting action claims fail. Partial observed
groups and missing/nonmaximal/unobserved scope parents fail even when their
individual records and envelopes are well formed. Concurrent import branches
retain every scope maximum. The [algorithm and limits](first-save-reopen-contract.md#executable-initial-import-validation)
state precisely what the result does and does not establish.

The new host-free Swift Testing cases include public/encrypted empty and
multi-batch imports; every required object's absence followed by redelivery;
wrong-but-authenticated digest/completion/page/body claims; omitted import
coverage; wrong exact reference indices/IDs; duplicate versus contradictory
repackaging; partial groups; concurrent and redundant action frontiers; several
groups/scopes in one object; and cancellation at every exposed check followed
by a successful retry. An independent Python/struct/hashlib fixture supplies a
complete public two-note/two-page repository, not merely bytes roundtripped
through the Swift encoder.

The whole suite now has **54 Swift Testing functions**, passing in both debug
and optimized builds on the arm64 development Mac. The independent fixture
checker, 17 client/type-boundary cases and app build pass; Xcode
emitted the existing sandbox/cache/Simulator warnings. No
editor/search code or TLA+ transition changed. `SegmentBootstrapSafety` assumes
valid initial evidence; these tests exercise part of that concrete assumption,
not a refinement proof or substitute for its persistence/publication checks.
Unchanged TLC configurations and startup benchmarks were not rerun.

```sh
make -C tests run-swift-storage
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release'
python3 tools/check-initial-bootstrap-fixtures.py
```

This is **not production activation**. The validator is read-only and returns no
barrier, pin or authority to edit. The initial-only path declines later mutation
history rather than omitting it. General Current/action reduction, indexed and
resumable large-bootstrap execution, complete private/current-cell codecs,
Foundation selected-store cutover remain needed. The ordinary SQLite save/reopen
and raw current-cell slice is now implemented in the Phase 2 report.
Repeated ancestry walks can take superlinear total time, so this worker/reference
implementation is not yet the production large-history scheduling solution.

The intervening startup work remains intact: level-3 zstd with capped training is
the selected **private current-cell candidate**; opportunistic full VACUUM is
optional maintenance, pending interruption/latency qualification. Neither affects
provider envelope zstd, bootstrap identity, exact immutable bytes or this initial
snapshot verification. This work adds no packed startup representation, new quit
barrier, current-cell codec choice or mandatory history scan at returning launch.

### Conformance strategy audit

Applied [the strategy](swift-storage-conformance-testing-strategy.md) to the
initial-bootstrap increment, specifically issuance (§3), contextual evidence
(TC-EVD-01), complete action frontiers (TC-ACT-01), startup evidence (TC-START-01),
static clients and mutation sensitivity (§§10–12).

- **Restricted issuance:** explicit private/fileprivate constructors replace
  synthesized module-wide constructors for checked bootstrap/envelope results.
  Scope frontiers are nominal, immutable values bound to the exact validated
  snapshot, collection, completion and scope. The 17 compilation cases include
  legitimate clients, forbidden fabrication from outside and inside the module,
  raw-set substitution and attempted decoding of checked history. Negative cases
  require the intended diagnostic at the intended source line; compiler/setup
  errors and unrelated locations fail the harness.
- **Near-valid inputs:** positive companions accompany wrong authenticated value
  commitments, omitted import coverage, incorrect snapshot bodies and incomplete
  scope maxima. Tests distinguish exact error categories. Descriptor tests use
  valid same-collection objects with the wrong Genesis pin or key ID. The AEAD
  failure test recomputes the outer locator after tampering, reaching actual
  authentication rather than failing the earlier exact-locator check. Body
  mismatch is tested through both public and encrypted envelopes.
- **Independent observations:** literal initial values and a separately assembled
  full public repository remain the byte/semantic oracle. The same-context-ID
  test checks two different valid histories' exact snapshot/completion bindings.
  The production validator issues the facts in every dynamic case.

`tools/test-bootstrap-mutations.py` compiles a fresh isolated package baseline,
then applies one source mutation at a time. It reuses downloaded dependencies,
not the workspace's compiled test binary. Named tests and exact assertion lines
must be discovered and reached; a wrong error, setup failure or missing test is
not credited. Self-checks challenge no-op injection, missing/ambiguous patch sites,
test-function lookup, zero discovery and diagnostic classification. Artifacts
retain source/fixture hashes, resolved dependencies, compiler/configuration,
binary hashes, exact patches and full logs. Inputs are synthetic; encrypted
fixtures use fresh production nonces, so repeated runs are semantically rather
than byte-for-byte identical.

| Mutation | Intended assertion |
| --- | --- |
| M07: accept a subset of the scope maxima | `scopeClaimsNeedTheirCompleteDeclaredCausalBasis`, missing maximum |
| Skip snapshot body equality | `snapshotMustMatchExactImportedRecord`, wrong body, both profiles |
| Accept incomplete completion ancestry | `authenticatedInitialHistoryCanStillBeWrong`, missing branch |
| Skip recomputed initial-values digest | Same test, consistently wrong claimed digest |
| Accept any same-collection Genesis object | `exactDescriptorGenesisIsNotJustAnyObjectFromTheCollection` |
| Omit descriptor key-ID binding | `matchingEncryptedObjectsCannotBlessADifferentDescriptorKeyID` |
| M22: reject valid selected context | The valid-history `#require` companion |

Run the focused challenge campaign with:

```sh
make -C tests run-swift-storage-mutations
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/arm64-apple-macosx/release/Modules
```

On 2026-09-14 the isolated debug baseline passed and all **seven** mutations
produced their targeted runtime assertion failures. Two earlier harness runs
exposed diagnostic-matching and same-line test-declaration lookup defects; those
were corrected and self-checked before the complete campaign passed. This does
not count their incomplete runs as successful detections. Full final evidence:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-bootstrap-mutations-kgbkvp9v/results.json`.
The source and runner reproduce the experiment; the temporary logs are not a
permanent conformance ledger. Optimized full-suite tests also pass; mutation
sensitivity was measured in debug, not asserted for every build configuration.

**Coverage boundary:** these are initial-import issuance tests, not an implemented
consumer's rejection of stale evidence, command capture, durable acceptance,
two-store exchange, general history reduction or activation. TC-EVD-01 and G1/G2
are therefore only partially covered by those bootstrap tests. The subsequent
Phase 2 work adds actual SQLite save/acceptance/reopen, contextual consumers,
strict C/Swift diagnostics and sanitizer checks, and removes the module-internal
fixed-nonce writer seams. Its report records remaining platform and release
qualification. No product policy or
TLA+ transition changed in this audit; unchanged TLC runs add no evidence here.

## Startup: remove the packed cache

Implement indexed `current_notes` loading and required `view_meta` authoring
context. Do **not** implement `startup_cache`, `view_changes`, cache epochs,
delta floors, packing workers or cache-publication work: these are removed from the design.
Keep acceptance/materialization batches, retained-history pins, exact source
references and the final startup-generation fence. This chooses the already
specified current-row path; it does not change provider snapshots or make current
rows the sole owner of history. The cache-only schema, formats, counters, workers and tests are removed; useful correctness tests now exercise current-row materialization.

The existing compiled comparison now has `rows-direct`: construct each actual
`NoteObject` directly from its SQLite row, rather than concatenating rows into
another packed buffer first. Every path constructs identical title/body/label
search caches and runs the same synchronous substring queries inside the measured
interval. Independent re-encoding checks the full common note fields outside
the timing; search hit counts must agree. Compare **total** time, since direct-row
decoding is interleaved with reading. All samples are separate processes.

SQLCipher/raw-key, 4-KiB pages, 100,000 unrelated historical 4-KiB objects,
five randomized trials per path/condition on arm64 macOS 26.6.2:

| Notes / target body characters | Cold direct rows | Cold packed | Cold compressed packed |
| --- | ---: | ---: | ---: |
| 1,000 / 256 | 12.43 ms | 13.08 ms | 11.58 ms |
| 10,000 / 256 | 116.44 ms | 108.48 ms | 107.91 ms |
| 1,000 / 4,096 | 102.37 ms | 101.41 ms | 96.09 ms |
| 10,000 / 4,096 | 1,005.60 ms | 998.15 ms | 952.58 ms |

These are medians, not an assertion of exact equivalence. Flat packing has little
benefit in this fixture; compression saves roughly 5–7% in the larger cases,
mostly reducing bytes read rather than the dominant note reconstruction cost.
That does not currently justify a second representation and catch-up protocol.
The performance guidance informed measuring complete initialization, not just SQL.

All **120 measured loads** passed exact-value/search equivalence and the cold-I/O
gates. Cold means `MS_INVALIDATE`, zero resident input pages measured with
`mincore`, and kernel read bytes at least as large as the encoded input. This
does not flush SSD/controller caches. Warm medians and every sample remain in
the artifacts below. This is not production Swift reducer/context decoding,
fragmentation after years of edits, full application launch, or journal recovery;
the existing SQLCipher crash/recovery probes cover a different boundary. Revisit
packing only if production measurements show a material gain, including those
costs. Its omission does not wait for those release measurements.

```sh
python3 tests/run-startup-storage-comparison.py --skip-build \
  --notes 1000 10000 --body-chars 4096 --history 100000 --repeats 5 \
  --conditions warm cold --kinds rows-direct flat compressed \
  --sqlcipher-build /path/to/qualified/sqlcipher --key-mode raw
# Repeat with --body-chars 256.
```

Raw artifacts (temporary; reproducible source is the lasting record):
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-startup-comparison-arel7mkn/results.json`
and `.../nv-startup-comparison-2fnrf8ug/results.json`.

The [aged-database follow-up](aged-current-row-startup-validation.md) measures
cleanly checkpointed/closed stores rather than WAL recovery. It finds a real
locality regression absent from the fresh fixture above: table-order startup can
take about 2.1 s versus a roughly 0.8 s packed baseline for the large mixed-note
case. Rewriting only current rows can restore near-packed speed, but scattered
freelist reuse defeats an unconditional guarantee. No mandatory quit rewrite,
full VACUUM or restored packed format is adopted. Direct table-order streaming and
bounded temporary allocations are now explicit requirements. The subsequently
adopted [opportunistic full-VACUUM policy](clean-quit-locality-strategy.md#adopted-opportunistic-full-vacuum-policy)
requires eligibility, benefit-lifetime and safe-interruption qualification before
automatic execution. The [next investigation](clean-quit-locality-strategy.md)
now supplies a concrete non-rewriting candidate: independently compressed cells,
page-size qualification and bounded read-ahead from a disposable physical page
list. It substantially improves the tested fragmented layouts without claiming
universal packing equivalence or demonstrating the periodic maintenance policy.

## Registered external undo

Four new cases use the public `shouldChangeTextInRanges:replacementStrings:` /
`didChangeText` editing protocol **with undo registration enabled**, in a named
outer group at a safe boundary. They test a prefix insertion, whole-body Unicode
replacement, multiple disjoint replacements, and an independent external edit
after native Undo. Exact undo/redo restores the external before/after states and
then the two earlier local typing groups separately. New independent edits clear
the ordinary native redo branch. No manual inverse or archived AppKit object is
used; earlier registration-disabled cases remain negative controls.

All four passed on arm64 macOS 26.6.2 and Intel macOS 14.8.9. This supports an
adapter that registers an already validated, causally eligible external action
without creating a second portable action. It provides **ordinary LIFO undo**, not
rebasing an old local range while leaving a newer overlapping remote edit in
place. Concurrent candidates, automatic derived merges, reviewed compensation,
IME input and actual NV shared-view routing still obey the existing router and
admission rules. No automatic `Undo Saved Edit` fallback is adopted for remote
body changes. Integration must demonstrate those paths rather than infer them
from `canUndo` or these sequential probes.

A fifth local case, `remote-registered-followup`, inserts another local typing
group after the external prefix edit and checks the entire Undo/Redo sequence:
later typing, external action, then both earlier typing groups and back again.
It passes on macOS 26.6.2. The four earlier registered cases and existing
unregistered negative/observation controls were rerun alongside it; artifact
`.../nv-native-undo-xdljqa2_/results.json`. This fifth case has not been run on
the Mini. Its VPN-assisted four-case run completed earlier; Mullvad was restored
and its connected status verified afterward.

Run `python3 tools/run-native-undo-probes.py --binary /tmp/notation-integration-tests/NativeUndoProbe --only remote-registered`.
Local artifact: `.../nv-native-undo-r6wc41nc/results.json`; Mini artifact:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-native-undo-hamc7y9w/results.json`.

## Recovery artifacts

`SelectedStoreRecordV1` is exactly **90 bytes**: magic `NVSEL1\r\n` (8),
version `u16(1)`, association ID (16), local-store ID (16), fresh selection
generation (16), SHA-256 (32) of `NV local selection\0v1\0` plus the preceding
58 bytes. IDs are nonzero raw bytes. The generation is a fresh random nonce,
not a reused integer or a causal clock. No strings, paths, secrets or provider
frontier are accepted. Wrong length, magic/version, IDs or checksum fail closed.
The checksum detects damage; it supplies neither authenticity nor root authority.

`RecoveryKeyV1` uses [Bech32m](https://github.com/bitcoin/bips/blob/master/bip-0350.mediawiki)
with HRP `nvrk`, a first 5-bit version value of 1, the 32-byte CK converted
MSB-first to 52 symbols with four zero padding bits, and six checksum symbols.
The canonical representation has exactly 64 ASCII characters. Accept all-lower
or all-upper case, not mixed case. Ignore only ASCII space/tab/CR/LF during paste
(maximum 1,024 input UTF-8 bytes); reject other spelling changes. Never autocorrect
an invalid key. Unknown version and bad padding remain invalid even with a valid
checksum. This is typo detection, not authentication: a decoded key must still
open the selected encrypted bootstrap. It does not name or authorize a root.

The Swift codecs include independent literal fixtures, all selected-record
truncations and one-bit corruptions, every single recovery-symbol substitution,
deletion and nontrivial adjacent transposition, bad-version/padding with recomputed
checksums, and spelling/length failures. `tools/check-recovery-artifact-fixtures.py`
reproduces the fixed expected bytes independently of Swift. Keys in fixtures are
public synthetic constants; actual key text must never enter diagnostics.

Envelope fixtures cover all three provider kinds, both suites and both
compression modes. Descriptor fixtures independently reproduce Argon2id,
HKDF/AES-GCM and exact hashes using Node/OpenSSL; recovery/initial snapshot
fixtures use independent Python construction. The pinned upstream Argon2
reference passes its own serial known-answer tests. The cryptography guidance
informed authenticated-before-decompressed processing and explicit nonce/key
boundaries; it does not replace cryptographic review or change the adopted
password-free/no-Keychain policy.

Validation: 38 Swift Testing functions pass in debug and release; eight ordinary
client/type-rejection checks pass. The SQL schema has 17 passing checks, including
its corrected **67,174,556-byte complete-envelope** ceiling. The prior bound
mistakenly allowed payload bytes only, omitting header/trailer overhead. All four
independent fixture-check commands pass. `./build.sh` passes with its existing
multiple-matching-destinations warning. No application editor/search code changed.
No TLA+ transition changed or unrelated TLC suite was rerun; these concrete tests
exercise byte/SQL/API assumptions beneath the existing models, not refinement.

Selected-record **activation is not implemented by this codec**. The Runtime
must first complete and reopen the replacement database and encrypted-profile
unlock descriptors; validate collection/bootstrap, pin/closure, unique private
state and generation; then use the owned, expected-current Foundation replacement
lane to install the exact selected record, verify readback and required barriers.
Initial selection uses exclusive creation. A same-generation retry reuses exact
record bytes; a new activation gets a new generation. Stale, ambiguous, failed
readback/barrier or wrong-kind/foreign occupants never trigger deletion of either
store. Recovery reopens/revalidates the selected candidate before issuing authority.
Both old and new databases plus journals remain recoverable. Never implement this
as a bare path rename or treat a codec roundtrip as crash qualification.

## Resource limits and scheduling

Use the fixed protocol ceilings, checked against **complete encoded units** before
admission and before attacker-directed allocation. The object payload is at most
67,108,864 decoded bytes; encoded/compressed payload at most 67,174,400; descriptor
at most 16,384; projection stamp at most 4,096; normalized password at most 1,024.
All are inclusive. Framing, every member and action metadata count toward the
payload cap. Before-state references normally refer to retained history; do not
duplicate old bodies unnecessarily. A single action cannot straddle objects.

No smaller arbitrary per-note limit is added. Compute the exact prospective
note/action/object size, including its real predecessors and scope references,
before authorizing an edit/import. Report a size failure without mutating the
accepted note or losing an external snapshot. Split bulk work into disclosed
independent groups, never a partial named action; a single oversized note needs
an explicit smaller-note/export choice. Reserve no fixed percentage by silently
dropping causal edges. Equality/one-sided merge rules remain available when the
10,000-LF-token two-sided merge ceiling requires review.

An isolated TK1 probe loaded and fully laid out 64 KiB, 1 MiB, 4 MiB and 16 MiB
of synthetic ASCII line text and retained a subsequent insertion. The 16-MiB
full-layout call took about 12.08 seconds; this **does not support the assumption
that AppKit necessarily blocks for minutes before our wire limit**. Input shape,
fonts, transformations and hardware matter. Therefore size validation is a real
admission requirement, not something UI slowness can substitute for. These are
single-run observations, not latency guarantees. Existing full-note startup
measurements exercise real NV search-cache construction separately.
The final probe uses an unbounded-height container and checks that all glyphs
fit its laid-out range. An earlier finite-height-container measurement was not
full-document layout and is not counted here. Final evidence: `.../nv-native-undo-fwfmqasg/results.json`.

For each vector, reject `count > remainingBytes / minimumEncodedElementBytes`
before reserve/allocation; each child remains independently bounded. Strings and
label totals are also bounded by the enclosing complete value/object. No maximum
collection note count, history depth/age, total action count, writer count or
total retained dependency count is introduced. A wide frontier can exhaust an
individual object: return an actionable size error preserving all inputs, not a
truncated frontier, timestamp/high-water substitute or age-based pruning.

Initial Runtime work budgets (scheduling parameters, **not wire validity**):

The ordinary-history [Runtime implementation](phase2-hardening-validation.md)
uses an even smaller database scheduling slice: one historical lookup per writer
turn, one ready candidate per turn, and one complete materialization batch per
transaction. Iterative ancestry state stays on a dedicated worker between reads.
Always yielding at these boundaries replaces counting up to the limits below;
it does not promise preemption within SQLite, envelope decoding or an indivisible
action/acceptance transaction. Large-bootstrap scheduling remains separate.

| Work | Per owner/pass bound | Exhaustion |
| --- | --- | --- |
| Graph validation / ready draining | 256 records or 8 MiB decoded work, checked between records; yield after 10 ms elapsed | Persist continuation/work queue, reschedule fairly; one individually valid larger record may finish in its own worker turn |
| Catalog enumeration | 1,024 entries per page/pass | Resume from adapter cursor or restart under the existing catalog fence; never publish an incomplete scan as absence |
| Provider bodies | Two outstanding requests, one 64-MiB decode per collection owner | Queue by exact ID, deduplicate; no main-thread await or second local sealer |
| Descriptors | One KDF globally; up to four distinct supported descriptors per explicit unlock attempt | Present remaining choices/failure, no automatic password guessing or weaker profile |
| Transient retries | Three attempts (initial, after 1 s, after 4 s), within a 15-s elapsed attempt deadline; at most one outstanding call per exact work item | Park with status; fresh relevant evidence, explicit operation or resolver re-presentation starts a new bounded attempt |
| Malformed/unsupported unchanged objects | One inspection per exact object hash + decoder version | Retain diagnostic/classification, not repeated hot-loop parsing; changed bytes/version permit reevaluation |

Use monotonic elapsed time for budgets, not wall time. A provider timeout does not
cancel a running coordinated accessor: retain its resources, fence late effects,
and do not start overlapping retries while it remains active. Closing a resolver
never blocks editing; waiting/retry state belongs to its exact version/operation.
Budget deferral is distinct from missing dependency, invalid encoding,
unsupported version, wrong scope, authentication failure and local I/O failure.
Only malformed/unsupported evidence is rejected or parked as such; deferred valid
work stays queued. Use iterative traversal with persistent visited/in-progress
state and exact edges for cycle detection; scheduling slices cannot reset cycle
evidence or reapply an accepted action. Prioritize prerequisites but rotate queues
so unrelated complete history can progress. These scheduling parameters may be
tuned without changing deterministic acceptance or merge results.

Pending payload storage is not a memory queue. Keep one latest durable snapshot
per pending file plus independently frozen admitted inputs; release only after
the specified transactional ownership/settlement rules. Memory pressure may evict
reconstructible decode buffers, not unique accepted/unpublished history, pending
snapshots, consent-sensitive recovery evidence or required pins. Disk exhaustion
is an explicit local failure, never a retention TTL. Apply bounded admission to
untrusted new work before allocating, not by deleting old accepted data.
