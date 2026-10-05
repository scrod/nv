# TODO: freeze proposal-5 file formats and encodings

Status: implementation checklist, updated 2026-10-05. This records the remaining work needed to turn the adopted format requirements into interoperable codecs. Unchecked items are not new policy decisions or permission to invent a different storage design.

Authority: [specification](../iCloud-Drive-Support-Spec.md), [Protocol](Protocol.md), [Encryption](Encryption.md), [ADRs](../adr), and [vocabulary](../../CONTEXT.md). The deliverable belongs to [implementation phase 1](Implementation.md#ordered-delivery-plan); [Verification](Verification.md#production-tests-to-implement) defines the adjacent implementation tests. Update those authorities when a format choice changes semantics. Preserve epoch-4 opening/recovery/export separately; no compatibility with unpublished segment drafts is required.

Current scope: freeze plaintext/shared primitives first. Attachments are unsupported; RTF/HTML and new rich-content codec/identity work are deferred, not prerequisites for starting those primitives. Do not generate a rich encoder from unfinished rules or silently convert existing input. Removing existing formats is a separate decision; legacy opening/recovery/export remains supported. See the [adopted scope](../iCloud-Drive-Support-Spec.md#input-and-content-scope).

The [first-save contract](plan/first-save-reopen-contract.md) specifies the initial record subset and bootstrap/runtime ordering. Core implements scalar/plaintext values, operation/action records, whole payloads, public/encrypted envelopes, descriptors/KDF, initial snapshots and recovery-key/selection codecs with independent fixtures. The [connected record contract](plan/phase3-connected-record-contract.md) adds all enabled plaintext action/state variants, editable concurrent Current and compensation validation through SQLCipher. General snapshots have [paged codecs and accepted-history verification](plan/general-snapshot-record-contract.md), followed by [complete acceptance/reconstruction](plan/phase4-bootstrap-reconstruction-validation.md). The [4C–4E report](plan/phase4-private-state-repair-copy-validation.md) covers bounded private records/nonempty settings and local repair/copy/selection. Physical projection metadata and platform consumers retain their later gates. A framed payload or identified operation still requires complete history acceptance.

## 1. Common encoding rules and identifier grammar

The subsequent [Phase 2 Runtime report](plan/phase2-local-runtime-validation.md)
adds ordinary causal validation, exact SQLCipher acceptance/reopen, raw current
cells and empty settings. The broader later-format checkboxes remain unfinished;
production runtime integration is no longer wholly absent.

- [ ] Publish a field table for each record: numeric tag, order, byte width or length prefix, required/optional status, allowed values, bounds, and semantic validation. Show offsets for fixed portions and a grammar for variable portions.
- [ ] Fix integer widths, unsigned big-endian encoding, boolean/enum representations, reserved values, optional-field presence, empty versus absent values, and treatment of trailing bytes. Do not serialize native structure padding.
- [ ] Define canonical set ordering and uniqueness for identifiers, labels, dependencies and fields. Specify the exact comparator: raw bytes versus decoded strings, normalization where required, and duplicate handling after normalization. Distinguish ordered member sequences from unordered sets.
- [ ] Define UTF-8 validity, embedded NUL handling, permitted empty strings, and normalization separately for each string field. Stored body spelling remains exact; conflict-recovery-key NFC rules must not silently normalize note contents.
- [ ] Fix UUID and digest widths and validation. Preserve the distinction between ordinary births, deterministic recovery identities, action IDs, operation IDs, writer epochs and collection IDs; UUID version bits alone do not classify a recovery note.
- [ ] Fix filename grammar for every provider and local artifact: UUID/hash text alphabet and casing, fixed widths, sequence radix/padding/range, separators and suffixes. Define sequence exhaustion handling without resuming an old writer allocator.
- [ ] Specify direct-child projection-name validation and reserved-name comparisons on supported case-sensitive/case-insensitive filesystems, including Unicode ambiguity and names such as `NV Data`. Reuse existing filename collision adjustment where its contract fits.
- [ ] Separate protocol-required version handling from optional extensions and local current-row versions. Unknown required formats remain unsupported evidence; specify whether any optional fields can be skipped, and whether their bytes participate in identity/authentication.

## 2. Segment payload, references and operation identities

- [ ] Define payload magic/version, section framing, counts, operation/action ordering, dependency-locator table and allowed empty sections. State how the decoder proves complete consumption of the payload.
  First-subset `ChangesPayloadV1` framing and whole-group sizing/consistency are implemented with literal and rejection tests. Empty framing conveys no bootstrap validity; no decoded prefix is exposed on failure.
- [ ] Encode external object locators and backward intra-segment references, including operation and action/state references. Validate index bounds, target type, exact ID agreement and closure before application.
- [ ] Freeze the canonical operation hash preimage and domain separator. Include the specified nonce, kind, target, payload, action membership and canonical parent IDs; explicitly distinguish hashed semantic fields from transport locators/indices. Supply vectors proving that transport representation does not change logical identity.
  First-subset kinds 1–6 now have literal semantic/wire/hash fixtures and distinct causal-parent/note-predecessor types. Reference-bearing future kind payloads still need explicit semantic expansion; exact external-object resolution and full action validation are not covered by this record decoder.
- [x] Assign operation tags and complete layouts for `Genesis`, `ImportComplete`, `Create`/`Import`, `Put`, `Delete`, `RecoverCopy`, `RetireConflict` and `AdoptAutomatic`. Note predecessors remain separate from causal parents; the connected contract and independent fixtures cover tags 7–9.
- [ ] Specify duplicate operation/action handling across valid envelopes and rejection of contradictory identity claims. Define validation order so a malformed member cannot publish a valid-looking prefix.
- [ ] Specify complete action-group framing and how multiple complete groups share one segment. Retain the requirement that each action record and all its members fit in the same segment; oversized bulk work must be split into disclosed groups before admission.
- [x] Finish explicit NV conflict disposition under the adopted [representation-only policy](Verification.md#nv-conflict-copy-disposition--adopted-policy): exact source birth/revision, copy birth/body key/slot and optional checked reuse reference. Complete durable actions establish dispositions independently of later output liveness. Reciprocal/reordered/retry and copy-modification/deletion/new-descendant tests qualify source selection separately. Apple-member disposition remains an adapter/application gate.

## 3. Note values and content formats

- [ ] Define the complete note-value field layout: title, body/content, labels, content-format tag, creation/modification display dates and any projection descriptor. Inventory legacy source fields and explicitly map each to synced values, private state, derived state or legacy-only data.
- [x] Fix display-date encoding: finite binary64 seconds from 2001-01-01T00:00:00Z; preserve finite precision/negative dates, canonical positive zero, reject NaN/infinities/encoded negative zero. Required dates are not absent or replaced by the current clock. Swift literal/rejection fixtures cover this value encoding, not legacy invalid-date UI handling.
- [x] Specify stored label values as exact nonempty UTF-8 tokens in strictly increasing raw-byte order, distinct from case-insensitive host lookup. Preserve case-distinct and canonically equivalent spellings as separate stored tokens; ordinary per-membership merge uses those tokens. Existing recovery-key NFC transformations remain separate. Swift fixtures cover case/normalization distinctions, duplicate/reversed encodings and empty-token rejection.
- [ ] Define the plaintext representation and its relationship to separately encoded note-file bytes, including encoding metadata and line endings. A projection digest hashes exact output bytes, which may differ from the canonical value payload.
- [x] Define plaintext value equality and digests, including which metadata participates. Exact title/body/label spelling and both dates participate in the full value digest; editable-field equality excludes dates. The first-save contract and Swift fixtures keep this separate from projection-byte and normalized conflict-identity digests.
- Deferred: RTF/HTML/rich-content profile, equality/digests and round-trip vectors, pending the format decision. No attachment support. Existing inputs require preservation or explicit unsupported/conversion handling; never truncate, flatten silently, or fetch external resources implicitly. Retaining a future rich codec would require exact received-byte identity independent of platform rendering/reserialization.

## 4. Actions, compensation and derived states

- [x] Freeze `ActionRecordV1`: ID/origin/previous origin, one scope, canonical complete scope maxima, kind, ordered members and exact before/after references. Tags 1–12 and their variant tails are implemented; allocated-ID comparison uses expanded identities.
- [x] Define state tags for fresh absence, direct value/Delete, equal/merge and automatic preservation. Exact dependency reconstruction is consumed by complete writer-history validation and current rows; independent literal fixtures cover the layouts.
- [x] Encode/validate Undo/Redo targets, per-group native remaining coverage, full-state/selected-branch restoration and fresh-birth mappings. Generic historical copies remain distinct from exact Recently Deleted exclusion.
- [x] Validate scope parents against declared causal inputs, including earlier complete groups in the same segment. The shared validator checks all represented maxima, complete membership, exact before/after states and origin references before acceptance.
- [x] Freeze versioned merge descriptors: policy ID, sorted represented inputs, unique base, full locators and result verification. Equal-value Current retains every represented revision.
  The [merge engine contract](plan/conservative-merge-contract.md) freezes the derived identity preimage and computed evidence; the [derived-state increment](plan/phase3-derived-state-validation.md) implements canonical transport subrecords and result verification against a supplied note graph. Equal/merged action/current-cell consumers and complete acceptance evidence remain the next integration gate.
- [ ] Freeze automatic-preservation evidence and its relationship to source revisions, Deletes, deterministic births and independently edited copies. A serialized descriptor/derived-index entry must not make an obsolete derived copy permanent or emit a new user action on receipt.
- [ ] Preserve existing plaintext conflict-recovery-key/slot and automatic-preservation vectors and the separation between body-only user recovery identity and automatic title/body/label preservation identity. Versioned rich-content identity domains/format vectors are deferred with rich codec work.

## 5. Genesis, import and provider snapshots

- [x] Encode supported v1 profile/codec/merge-policy requirements and initial import identity in Genesis, with the exact sorted note-set count/value digest preimage/domain. Empty and multi-batch initial imports have executable validation; production large-import scheduling remains a Runtime gate.
- [x] Define ImportComplete coverage and validation against the Genesis commitment. Initial-bootstrap tests cover missing, semantically duplicate, contradictory and concurrent/reordered batches; complete groups cannot be partially observed. The separate later-history reducer is not enabled by this completion.
- [x] Define general snapshot root/page payloads, page locators, ordering, counts, digests, represented frontier, note/action/revision indexes and required history references in the [general snapshot record contract](plan/general-snapshot-record-contract.md). Core implements the seven enabled-state record classes with independent literal fixtures; Runtime captures neutral accepted state and verifies an explicit logical cut against exact accepted occurrences. See the [first Phase 4A qualification](plan/phase4-general-snapshot-validation.md) for its integration boundaries.
- [ ] Specify how a snapshot is validated against its claimed retained closure and how missing pages, competing snapshots and unrepresented segments are handled. Authentication alone does not establish a correct derived snapshot or global freshness.
  Initial-only roots/pages have independent complete-repository bytes and connected validation against imported values/actions. The general verifier reconstructs the claimed cut, checks whole groups and compares all continuation claims, including valid alternative transport occurrences. General root/page acceptance, unaccepted-history verification, snapshot-tail recovery and competing-snapshot selection remain distinct implementation work.
- [x] Specify bounded data/index pages and a fixed-size root for arbitrarily growing manifests in the general snapshot contract. Per-object limits apply to individual page/record payloads; counts and byte ranges use checked u64 arithmetic. Snapshots preserve required ancestry under the existing retention policy.

## 6. Envelope, bootstrap and secrets

The [common envelope](Encryption.md#common-object-envelope-version-1) already specifies its 124-byte header, numeric kind/suite values, authentication domain and trailers. Carry those choices forward; remaining work is to make the full encoding executable and reviewed.

- [x] Produce complete public/encrypted envelope fixtures with fixed test-only keys/nonces, HKDF inputs, associated data, compressed/uncompressed payloads, tags/checksums and final segment IDs. Production retries reuse sealed bytes.
- [x] Fix the [single-frame zstd profile](Encryption.md#compression-profile): explicit exact content size, dictionary-free decoding, 64-MiB window/output bounds, truncation, concatenated/skippable frames and trailing-byte rejection. Authenticate before bounded decompression; test both suites with valid authentication around malformed frames.
- [x] Freeze encrypted and public descriptor magic, tags, offsets, field lengths, checksum/authentication domains and descriptor-ID calculation. Include genesis locator, profile/codec requirements, KDF profile, salt, nonce and wrapped-key fields as applicable.
- [ ] Specify descriptor consistency validation across collection/key/profile/genesis and concurrent same-key rewrap descriptors. Preserve the pinned encrypted-profile downgrade checks.
- [x] Freeze passphrase normalization/length vectors and Argon2 profile encoding; pin the dependency revision and known-answer tests. The vendored reference revision passes upstream serial known-answer tests and matches the independent Node/OpenSSL vector. Cross-platform builds and production review remain qualification gates.
- [x] Define the user-facing encryption-recovery-key representation and decoder, including typo detection. `RecoveryKeyV1` supplies key material only; the runtime must still authenticate/validate the selected bootstrap before activation.
- [ ] Record cryptographic review of the assembled encoding and its domain separation before production use.

## 7. Host-private formats

The [Phase 4C–4E plan](plan/phase4-private-state-repair-copy-plan.md) now has
implemented bounded private layouts/reference transactions, complete backup,
complementary repair and verified local activation. Their
[qualification report](plan/phase4-private-state-repair-copy-validation.md)
separates executed production checks from later provider/host adapter work.

- [x] Define the private SQLite role/transaction mapping and current-row DDL in [LocalStore](LocalStore.md). This is contract completion, not a production adapter or complete inner-record codec.
- [x] Supply the [initial executable SQL schema](plan/sqlite-local-schema.md) for exact objects/occurrences, accepted history, distinct graph edges, ready work, pins, private groups and current-row startup, with direct SQL constraint/transaction checks. This covers the first-save subset, not pending/projection tables, later action variants or production validation.
- [x] Specify the [database-key/recovery lifecycle](LocalStore.md#database-keys-and-password-free-recovery): public nonsecret key for password-free recovery, CK-derived encrypted DB key, exact existing wrapped-key descriptors outside SQL, add-only same-CK password changes and optional remembered unlocking. No second database password/key-wrapper protocol or routine native rekey.
- [x] Freeze the bounded selected-store-record encoding and qualify controlled local durable activation with fresh ownership, expected generation, synchronization/readback and preserved old entries. The existing wrapped-key descriptor codec uses `unlock/<hash>.nvkey`; platform credential provisioning and real provider selection effects retain later gates.
- [x] Encode scoped local association, bootstrap/retained descriptor/history pins, bounded collection settings and pending observation settlements. The [private-record contract](plan/private-record-contract.md) freezes layouts and fresh consumer checks. Host bookmark interpretation, broader UI preferences and actual physical projection receipts remain adapter work.
- [x] Specify pending-file semantic records and commit/recovery ordering in [Protocol](Protocol.md#pending-file-commit-and-recovery-records): independent latest/frozen ownership, expected-current metadata generations, exact operation lookup, no-op association, provisional claims, atomic receipt/pending settlement, and release after uncertain completion. This is design completion, not an implemented codec.
- [x] Implement bounded private snapshot/item/reservation/settlement records in encrypted database pages, with independent golden bytes, exact reference transactions and fresh-process first/replacement retention, lost callback, same-birth Delete and repeated I/O failure checks. Actual file-installation/consent integration retains Phase 6's gate.
- [x] Inventory existing preferences and remembered cursor ranges, map their portable settings fields, and preserve nonempty settings through rebuild/repair. Platform interpretation and legacy migration remain with the application; action origins/portable undo history remain repository records.
- [x] Freeze raw current cells and authoring context with independent byte/semantic vectors. Version 2 adds represented/all-head occurrences, exact derived/automatic state and typed deterministic identities; the [connected contract](plan/phase3-connected-record-contract.md) specifies its layout. Paged-context formats remain later work. Startup loads complete current bodies and editing context.
- Removed: packed startup-cache layout/fixtures, construction certificates, cache-only delta tables/pruning and batch tokens. [The benchmark](plan/remaining-storage-validation.md#startup-remove-the-packed-cache) supports current-row startup as the only design.
- [x] Specify current-row materialization, ready draining, exact accepted-prefix catch-up and final owner/view-generation publication checks in [LocalStore](LocalStore.md). Healthy startup never requires reading all old history.
- [x] Implement distinct actual-opening outcomes for malformed/unsupported required-private state, isolated pending failure, access/credential uncertainty and rebuildable derived rows. Explicit incomplete salvage preserves fragments; existing incompatible stores receive an outcome rather than initialization over their evidence.

## 8. Plaintext projection metadata

- [ ] Freeze `NVProjectionStampV1` under the exact name `org.notationalvelocity.projection#S`: version/tags, collection, birth, format, exact file digest and represented-state reference.
- [ ] Cover ordinary revision, equal-value, two-input merge and automatic-preservation variants with exact locators and canonical ordering.
- [ ] Define the complete portable projection descriptor carried inside segments and its relationship to stamps and private receipts. Decide exactly when it is required or absent under each profile.
- [ ] Supply malformed, foreign, copied, stale, body-mismatched and missing-dependency examples. Matching bytes/stamps do not independently authorize aliasing or deletion.
- [ ] Preserve the 4-KiB ceiling and complete omission fallback for oversized stamps. Do not truncate represented input sets or introduce a sidecar. Distinguish optional stamp failure from uncertain body/mandatory-metadata installation.

## 9. Limits and rejection behavior

Maintain one explicit limits table with units, inclusive/exclusive boundaries, validation stage, and outcome. Existing values include the 64-MiB decoded object ceiling, 64 MiB + 64 KiB encoded ceiling, 16-KiB descriptor ceiling, 4-KiB stamp ceiling, 1,024-byte normalized passphrase limit, and 10,000-line two-sided merge limit. Resolve inconsistent “proposed” wording without silently changing adopted values.

[Concrete budgets and measurement results](plan/remaining-storage-validation.md#resource-limits-and-scheduling)
now fix vector preallocation checks, resumable work slices, request/KDF/retry
bounds and actionable oversized-group failure. These are specified Runtime
requirements, not an implemented scheduler. Current codecs enforce their full
wire bounds; later record-specific codecs and actual admission checks remain.

- [ ] Measure realistic note/input sizes and rates, whole-note memory and NSTextView/synchronous-search responsiveness; give every supported value adequate encoding headroom including its action metadata and required before/after representation. Distinguish practical editable-value limits from wire/security ceilings. No speculative live-note paging or oversized-note subsystem. A proposed change to an already fixed ceiling needs explicit review and new vectors, not a generator default.
- [ ] Set limits for counts and sizes inside individual records/envelopes: operations, actions, members, parents, locators, strings, labels, manifest entries and private-state fields. Validate arithmetic before allocation and indexing. Attachment limits are unnecessary; rich-record limits are deferred with that format.
- [x] Define bounded graph traversal and dependency-fetch work: iterative traversal, cycle detection, per-pass memory/work/request budgets, yielding and resumption. Distinguish an invalid object from valid history whose processing is deferred by a scheduling budget. Runtime enforcement/qualification remains outstanding.
- [x] Do not impose a total-history-depth/age limit that eventually invalidates an ordinary long-lived collection. Bound parsing and work per pass while retaining complete required ancestry. An overflowing frontier/group is an actionable failure preserving its inputs, never truncated parents or a lifetime cutoff.
- [x] Define descriptor/KDF attempts, duplicate inspection and repeated malformed-object processing bounds without silently forgetting accepted history. Temporary unavailability parks bounded work rather than permanently rejecting it; stored unique pending data has no eviction TTL. Runtime enforcement remains outstanding.
- [ ] Provide typed outcomes for malformed, unsupported, wrong scope/profile, authentication failure, incomplete dependency closure, oversized input and resource-budget deferral. Define which unit is rejected/parked and whether unrelated complete history may continue.

## 10. Golden vectors and completion criteria

- [ ] Check in annotated valid byte fixtures for every record/variant, with decoded values, canonical preimages, expected hashes/IDs and expected complete envelope bytes where keys/nonces are fixed.
- [ ] Include empty, singleton, multi-member, Unicode, date-boundary and at-limit cases for each enabled codec; rich-content fixtures are deferred with that codec. For each limit test below/at/above it; include truncated lengths, overflow, unknown tags, invalid ordering, duplicates, forward references and cycles.
- [ ] Verify identical semantic encodings and hashes on Intel and Apple Silicon. Test transport-reference expansion separately from operation hashing, and public/private/collection replay boundaries separately from basic round trips.
- [ ] Use independent expected bytes and values. Encode→decode through the same implementation alone cannot detect a shared encoding mistake. Existing merge/recovery vectors remain regression inputs.
- [ ] Add a small executable codec/reference check using the existing test infrastructure. Fuzz the bounded decoding entry points once they exist; no live provider is needed to validate a format.
- [ ] Update Protocol/Encryption with final tables and link vectors from Verification. Recheck spec, ADR and CONTEXT consistency; update/run relevant models if the choices change semantics.

Completion means an implementer can construct and reject the same objects from the written specification and fixtures without inventing field layouts, identity rules or failure policy. Finish shared primitives and operation/value encodings first, then actions/derived states, bootstrap/snapshots, private formats and stamps. Resolve semantic blockers before freezing their dependent records; this checklist does not enable deferred co-add, GC or a new metadata directory.
