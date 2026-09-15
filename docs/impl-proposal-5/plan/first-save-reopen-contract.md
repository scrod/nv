# First save/reopen: encoding, bootstrap and runtime contract

Updated: 2026-09-14. This is the concrete first increment of the [roadmap](swift-storage-implementation-plan.md). The working local subset and qualification boundaries are recorded in the [Phase 2 report](phase2-local-runtime-validation.md); the whole storage engine is not complete. The [specification](../../iCloud-Drive-Support-Spec.md), [Protocol](../Protocol.md), [Encryption](../Encryption.md) and ADRs retain authority over behavior. Nothing here changes causal deletion, Current-only editing, ownership, local barriers or provider guarantees.

## 1. Scope and implementation status

The first complete local milestone includes both public and encrypted envelopes, initial collection bootstrap, complete ordinary Create/Put/Delete action groups, Local State pinning and fresh-process replay. It must contain two notes so unchanged-note preservation is observable. A test must not insert an already accepted history/receipt directly to bypass bootstrap or installation.

| Deliverable | Present status |
| --- | --- |
| Exact UTF-8, display dates, labels and complete plaintext values below | Implemented in `NVStorageCore`, with literal fixtures and rejection tests |
| Value digest, nominal operation identities, six operation kinds and operation-reference records | Implemented with SHA-256 fixtures, intrinsic validation and bounded transport decoding; **not** action/graph validation |
| First-subset action records and complete changes-payload framing | Implemented with group consistency, canonical expansion and exact direct-reference checks; **not** causal/Current/bootstrap validation or authentication |
| Public/encrypted envelopes, descriptors/KDF, initial snapshot, selected-store/recovery-key encodings | Implemented with independent fixtures; production cryptographic/platform review remains |
| Complete initial-import semantic validation | Implemented below, across exact envelopes/actions/pages; no durability or activation authority |
| Private/current-state and later action/state record layouts | Raw single-value current cells, ordinary authoring context and empty settings implemented with [frozen layouts and independent fixtures](phase2-local-runtime-validation.md#frozen-private-record-layouts); later variants remain in Format TODO |
| Complete bootstrap construction and recovery ordering | Implemented through exact bootstrap validation, SQL acceptance and separate materialization |
| Client/runtime methods and ownership transitions | `LocalStoreSession`, immutable captures, restricted receipts, real directory ownership, generation checks and retry/quiesce implemented |
| Initial SQLite history/private-group/current-row schema | [Executable DDL](sqlite-local-schema.md), SQL checks and real SQLCipher adapter; DDL and bundled resource are checked for exact equality |
| Installation, pin commit and fresh opener | Working both-profile local path; [process, VFS, compiler and mutation qualification](phase2-local-runtime-validation.md); final selected-store cutover remains later work |

The package has functional `NVStorageCore` and `NVStorageRuntime` targets using Swift 6 language mode and a Swift 6.1-or-newer build toolchain. It pins Swift Crypto 4.5.2, including upstream Linux `SymmetricKey: Sendable` support; `Package.resolved` records its revision and the transitive Swift ASN.1 resolution. The reproducible local build pins SQLCipher 4.19.0. SHA-256, HKDF/AES-GCM, vendored Argon2id and zstd provider-envelope compression have executable checks. The [dependency manifest](https://github.com/apple/swift-crypto/blob/4.5.2/Package.swift) selects CryptoKit on Apple and a different backing implementation on other platforms. A successful Mac test does not qualify that other implementation. Private current-row zstd/dictionary tuning remains the separate [selected candidate](clean-quit-locality-strategy.md#bounded-dictionary-tuning-selected-for-the-candidate); Phase 2 uses raw cells as its correctness baseline. Add the Apple target with its first working behavior. macOS 11.5 is the deployment declaration; executed platforms and remaining qualification are recorded in the [platform audit](phase2-platform-and-type-audit.md). No application target imports this package yet.

An initial development implementation may report richer operations, derived-state variants and native compensation as unsupported until implemented. It must never skip them and expose an incomplete collection as editable. This is a development milestone, not a new reduced-capability production profile or permission to ship without proposal-5 features.

The [actor-owned database](actor-database-adoption.md) keeps complete synchronous
SQL turns on its serial executor. The general Core `OrdinaryHistoryV1.validate`
entrypoint and its lookup callbacks are asynchronous; current-basis and bootstrap
checks retain synchronous shared reference/action rules. Runtime client methods,
encoded formats, acknowledgment and retry contracts remain unchanged. Async
history validation rechecks the accepted prefix at each read and at final commit.

## 2. Common scalar rules

These rules are for new payloads; the existing envelope/header and conflict-identity encodings retain their specified widths/domains.

| Notation | Bytes and validation |
| --- | --- |
| `u8`, `u16`, `u32`, `u64` | Unsigned big-endian integer of the named width; checked arithmetic before conversion/allocation |
| `ID16`, `Hash32` | Exact 16 or 32 raw bytes. Public Swift APIs use distinct nominal identities, not interchangeable UUID/hash aliases. Zero is allowed only where explicitly the protocol's sentinel; no UUID-version inference of birth provenance |
| `bytes` | `u32(length)` followed by exactly that many bytes; no terminator/padding |
| `text` | `bytes` containing strictly valid UTF-8; reject overlong sequences, surrogate scalars, out-of-range scalars and incomplete sequences; no replacement characters inserted by decoding |
| `vector(T)` | `u32(count)` then exactly count elements; validate remaining byte bounds before allocating, parse incrementally, and require complete consumption |
| `optional(T)` | `u8(0)` alone for absent, or `u8(1)` then T; other discriminants invalid |
| `set(T)` | Vector strictly increasing by the specified **unsigned raw byte** key, with duplicates rejected, not silently normalized away |
| `DisplayDate` | Eight-byte unsigned big-endian encoding of the IEEE-754 binary64 bit pattern for finite seconds since 2001-01-01T00:00:00Z. Preserve finite legacy precision, including negative/fractional dates. Authoring maps negative zero to positive zero; decoding rejects negative zero, NaN and infinities |

Stored title/body spelling is exact; empty and embedded-NUL text is representable. An empty body is not deletion. UI/path constraints belong to those separate boundaries. An app adapter must not truncate at NUL or pass these values to C string APIs as if terminated text. A required date is not optional; an invalid legacy date requires explicit source-preserving migration handling, not a clock-derived replacement. Out-of-calendar presentation must not change the stored number or affect causal selection.

The scalar text ceiling is the existing 64-MiB decoded-object ceiling. It is **not** a promise that a 64-MiB body plus its record/action overhead fits one segment. Complete encoded-group sizing governs representability; it must include reference tables, values and action metadata before admission. The count/length prefix's larger numeric range never authorizes allocation beyond the enclosing object's remaining bytes. More restrictive practical editing/batch limits remain the measurement task in Format TODO; no new arbitrary small note cap is adopted here.

No optional unknown fields are skipped in these v1 records. Unknown version/kind means unsupported evidence; malformed framing is invalid. Required-but-unimplemented variants do not mean an empty value. Existing explicit conflict-key/slot/automatic-preservation hashes continue using their **u64** counts/lengths and NFC rules, not this generic u32 framing.

Locator filenames use lower-case hexadecimal: 32 digits for writer epochs and 64 for hashes, without UUID hyphens. Sequence text is exactly 20 zero-padded decimal digits representing the u64; allocation starts at zero in a fresh writer epoch. Provider paths remain `NV Data/v1/segments/<epoch>/<sequence>-<hash>.nvseg` and `keys/<hash>.nvkey`; private objects are exact BLOBs indexed by identity in [Collection.sqlite](../LocalStore.md), not a parallel object-file tree. Exhaustion allocates a fresh epoch rather than wrapping; the encryption epoch's existing 2^20-object limit applies sooner. Received noncanonical/provider-renamed leaves may be inspected as bounded candidate objects under the existing discovery rules, never followed as embedded paths or discarded solely for spelling.

### Legacy field mapping and labels

| Existing input | New owner |
| --- | --- |
| `uniqueNoteIDBytes` | Validated note birth; preserve on initial migration, allocate fresh births for restoration |
| `titleString`, `contentString.string` | Exact title/plaintext value; importing an attributed rich document still requires its explicit conversion/support decision |
| `labelString`, `labelSet` | Label value/spelling and membership rules below; neither a shared mutable LabelObject nor an archived Cocoa graph |
| `createdDate`, `modifiedDate` | DisplayDate; matches `NoteObject`'s existing double serialization and CFAbsoluteTime origin |
| `filename`, `fileEncoding`, intended format | Projection descriptor/private transition work, not birth identity or native Cocoa enum bytes in the body codec |
| File IDs/times/snapshots/merge-base tracking | Private, generation-bound observations requiring fresh checks |
| `selectedRange`, UI preferences | Independently versioned private host settings; never provider action payloads |
| LSN, delegate, label/search caches, undo manager | Runtime state or derived indexes; no persisted authority/native invocation |
| `syncServicesMD` | Legacy-only; no modern causality or deletion-retention role |

`LabelObject.m` lowercases names for association but retains spelling; `NoteObject.orderedLabelTitles` obtains tokens from `NSString.labelCompatibleWords`, which splits whitespace/comma/semicolon. Do not replace this with Swift String's canonically equivalent equality or full case folding: neither is the existing rule. A local Foundation probe confirmed that `Work`/`work` share a lowercase key, `ß`/`SS` do not, and composed/decomposed `é` remain different NSString association keys. This is one-host evidence, not a cross-platform Unicode proof.

The chosen wire shape is `LabelEntry = text(spelling)` and `labels = set(LabelEntry)` sorted by exact spelling bytes; an entry is nonempty. This preserves the **stored token values**, not the lossy shared lookup index. `NoteObject` archives `labelString` separately, and `labelCompatibleWords` retains case-distinct tokens. Capture those tokens, not the shared `LabelObject` prototype's spelling. Thus `Work` and `work`, or composed/decomposed `é`, can both be represented without losing a user's stored spelling. Exact duplicate tokens are rejected on the wire; authoring canonicalizes order. Token order/separators are not identity in the spec's canonical set.

Portable per-label merge membership uses these exact token bytes, following the existing per-membership rule. A spelling change is removal/addition of stored tokens; independent case changes can preserve both spellings, just as the legacy label string can contain both. Case-insensitive search/filter association remains a separate host index; this package does not change it. No new portable lowercase/case-fold dependency is needed to encode, hash or merge label values. The existing automatic-conflict identity's NFC label transformation remains a **different**, explicitly prescribed computation. Do not use that lossy recovery-key transformation as ordinary label-value equality.

## 3. First record layouts

Fields in each row are concatenated in the displayed order. Each record is versioned by its enclosing payload unless it carries a version below. All vectors are length-prefixed; all bodies must be consumed exactly. These tables assign byte structure, not new semantic permission.

### Values and references

| Record | Field sequence |
| --- | --- |
| `NoteValueV1` | `u8(format=1)` (plain UTF-8), `text(title)`, `text(body)`, `labels`, `DisplayDate(created)`, `DisplayDate(modified)` |
| `SegmentLocator` | `ID16(writerEpoch)`, `u64(sequence)`, `Hash32(segmentID)` — 56 bytes |
| External operation reference | `u8(0)`, `u32(locatorTableIndex)`, `u32(operationIndex)`, `Hash32(expectedOperationID)` |
| Earlier local operation reference | `u8(1)`, `u32(operationIndex)`; index strictly before the referencing operation for causal/note parents |
| External action reference | `u8(0)`, `u32(locatorTableIndex)`, `u32(actionIndex)`, `ID16(expectedActionID)` |
| Earlier local action reference | `u8(1)`, `u32(actionIndex)`; index strictly before the referencing action |

Dependency tables are sets of locators sorted by their 56 bytes. Resolve references against exact authenticated objects, index bounds, record type and expected identity. The external lookup must not search for any convenient matching ID in another object. Before/after action references point to the already parsed operation section: a before-state cannot depend on the action's new effect, and an after-state must be that action's actual member result. Snapshot roots/pages have no local operation/action section: their references must be external. This is not permission for forward operation-parent edges or graph cycles.

Projection descriptors are intentionally absent from the initial value codec. They remain separate typed claims introduced with projection support; changing an output filename must not change note birth or silently change a body. Exact stored-value equality compares all encoded fields, including dates. **Editable-field equality for source reduction** compares title/body/labels/format separately; a date-only difference must not manufacture a content conflict. Keep the birth creation date and combine modification dates by the existing display-only maximum rule without forgetting represented revision IDs. `PlaintextNoteValue.hasSameEditableFields` supplies the plaintext comparison, not a merge or head-selection result. A value digest is SHA-256 of ASCII `NV note value\0v1\0` followed by the full exact encoded value, including dates. It is distinct from projection-byte digests and preexisting conflict-recovery keys.

### Operation and action framing

Changes payload: ASCII `NVCHG1\r\n`, `u16(1)`, dependency locator set, `vector(bytes(operationRecord))`, `vector(bytes(actionRecord))`. Operations are topologically ordered; actions are ordered with their previous-origin/scope dependencies first. All members of each action reside in this payload. System bootstrap operations have no action membership; every ordinary note mutation belongs to exactly one complete action.

An operation record contains: `Hash32(claimedID)`, `ID16(nonce)`, `u8(kind)`, `optional(ID16(actionID))`, `optional(ID16(targetBirth))`, causal-parent references sorted by expanded operation ID, note-predecessor references sorted by expanded operation ID, then `bytes(kindPayload)`.

Canonical operation identity is SHA-256 of ASCII `NV operation\0v1\0`, followed by nonce, kind, the same optional action/target fields, `set(Hash32(causalParentIDs))`, `set(Hash32(notePredecessorIDs))`, and `bytes(kindPayload)`. Reference-table positions, locators, claimedID and enclosing envelope hash are absent from this preimage. For this first subset, kind payloads contain no transport references. Future reference-bearing variants require explicit semantic expansion, not hashing their locator bytes under this definition.

| Kind tag | Required target/membership and payload |
| --- | --- |
| 1 Genesis | No target/action/parents/predecessors. `ID16(importID)`, `u8(profile)` (1 plaintext, 2 encrypted), `u16(noteCodec=1)`, `u16(mergePolicy=1)`, `u64(initialCount)`, `Hash32(initialValuesDigest)` |
| 2 ImportComplete | No target/action/predecessors; causal closure covers Genesis and all initial imports. `ID16(importID)`, `u64(initialCount)`, `Hash32(initialValuesDigest)` |
| 3 Create | Target fresh birth, required action, no note predecessors; complete NoteValueV1 |
| 4 Import | Same creation requirements and value; initial or external import is distinguished by validated bootstrap/action context, not pathname identity |
| 5 Put | Target existing birth, required action, exact Current-represented note predecessors; complete NoteValueV1 |
| 6 Delete | Target birth, required action, empty kind payload and empty note-predecessor set; causal parents cover actually observed revisions |

Other tags remain unassigned/unsupported here. No new encoding of RecoverCopy/RetireConflict/compensation is inferred from their omission. The development writer must decline commands needing those variants, including deletion of a deterministic conflict birth; it cannot emit only half of the required group.

#### Implemented operation boundary

`IdentifiedOperation` computes its ID from an immutable `OperationEffectV1`, `OperationNonce`, `CausalParentSet` and distinct `NotePredecessorSet`. The effect enum requires action/target fields for ordinary mutations and omits them for Genesis/ImportComplete. Intrinsic checks require no parents for Genesis, a nonempty causal-parent set for every other kind (including an empty collection's ImportComplete, which still observes Genesis), and nonempty note predecessors only for Put. These are necessary shape checks, not evidence that the supplied ancestry is true. The hash and fixture-preimage methods share the same semantic field traversal.

`OperationRecordV1` encodes/decodes one record against a canonical `DependencyLocatorTable` and an explicit earlier-operation prefix. Authoring sorts unique references; decoding rejects unsorted or duplicate expanded IDs, unknown discriminants, invalid widths, forward/local out-of-range references, mismatched claimed hashes and trailing bytes. Encoding rechecks the earlier prefix so a retained record cannot silently acquire different parent IDs. Record sizing includes its actual reference encodings and full value before allocating output; the enclosing payload/action must subsequently account for its **additional** overhead.

An external reference's expected ID is still a **claim**. Decoding retains its exact locator and operation index even when the object is unavailable; the record API does not fetch or authenticate objects. The segment/closure validator must check that exact object's index, record type and ID, and reject a wrong index even if another object happens to contain the expected ID. `ChangesPayloadV1` supplies each record's actual earlier section prefix. Neither `IdentifiedOperation` nor `OperationRecordV1` proves a fresh birth, valid Current scope, complete bootstrap, correct action membership/before-after state, graph closure or durability. Runtime performs the additional checks and actual acceptance transaction before issuing a receipt; provider publication remains later work.

First ordinary action record: `ID16(actionID)`, `ID16(originID)`, `optional(ActionReference(previousOriginAction))`, `u8(scope)` (0 collection, 1 note followed by ID16 birth), scope-parent references sorted by expanded action ID, `u8(kind)` (1 saved edit, 2 rename, 3 labels, 4 create/import batch, 5 delete batch), ordered `vector(u32(memberOperationIndex))`, and affected-state entries sorted by birth.

Each affected entry contains birth plus before/after state references. State tags for this subset: `0` fresh-birth absence (no payload), `1` full value operation reference, `2` logical absence with its Delete operation reference. Absence tag 0 is valid only before a genuinely fresh creation, never as missing/unread evidence or after deletion. After tag 2 must reference the group's actual Delete. Exactly one entry accounts for each affected birth. Existing derived/merged before-states require their later codec; do not collapse them to whichever revision is convenient.

Action IDs are allocated, not hashes. Compare duplicate action claims using fully expanded canonical IDs/state references and metadata, not locator/index bytes. Validate complete membership, scope maxima, origin predecessor, target types and exact before/after agreement against the writer's declared inputs. A malformed action invalidates its whole segment; no prefix publication. The authoring order remains allocation → operations/IDs → complete action record → framing → sealing, without an action-record hash cycle.

#### Implemented action and payload boundary

`ActionRecordV1` implements the five ordinary kinds and three state-reference tags above. `ActionV1` expands transport references into nominal identities for comparing claims, preserving ordered members while canonicalizing scope-parent and affected-birth sets. Encoding rechecks the exact operation/action context; decoding rejects noncanonical order, duplicates, unknown tags, invalid indices and unconsumed bytes. Action-local edges can only reference earlier actions. Expansion of an external ID is not verification of its target or consistency with another claim for that ID.

`ChangesPayloadV1` frames complete operation/action sections and bounds the **aggregate** size including the table, counts, record lengths and actions. It checks unique identities within each section, complete in-payload membership and ownership, kind/member compatibility, exact affected-birth coverage, note-scope agreement, and state reference shape/type/birth where the target is local. After-states must name members of their own group; non-creation before-states cannot name that group's new effects. Local previous-origin and scope-parent targets must match their respective origin/scope. A failure returns no decoded prefix. Bootstrap-only operation sections need no action; parsing empty sections is not evidence of a usable collection.

`checkExternalReferences(at:resolve:)` checks **direct** references at the exact locator, section index and expected identity, rejecting external self-reference and missing dependencies. It checks referenced value/Delete types, births, action scopes and origins; no fallback search by ID is permitted. The resolver's payloads and their locator bindings must ultimately come from authenticated objects. This API does not authenticate caller-supplied labels, walk transitive closure or issue a validated-history capability.

`InitialBootstrapValidationV1` supplies transitive/exact-reference, duplicate-claim, fresh-import, causal-coverage, scope-maximum and commitment checks for the initial-import-only history described below. `OrdinaryHistoryV1` now validates Create/Put/Delete groups against the declared writer history, including saved edits, rename and labels, complete before/after state, scope maxima and observed previous-origin links. It checks the actual final member, not merely membership of the claimed after-state. Runtime invokes these checks before acceptance. Concurrent/derived states, compensation and richer actions still require later reducers; the first path rejects unsupported reduction rather than exposing a partial collection. Neither a decoded payload nor SQL constraints substitute for semantic validation.

For an eligible single ordinary group, Runtime may obtain the prior state from the
complete current materialization under the same serialized acceptance transaction.
The [checked-current-basis contract](current-basis-validation.md) specifies exact
parent/frontier, affected-row, fresh-birth and context checks. The same ordinary
semantic checks and exact-reference checks still validate the new group. Older,
divergent or incompletely materialized inputs retain full declared-history validation.
Retained object and authoring operation frontiers advance by adding genuinely new
records and removing their direct parents; duplicate records leave logical effects
unchanged. These changes apply equally to recovery catch-up and introduce no new
record format or persistent validation cache.

`ChangesPayloadV1Tests.swift` uses independently assembled literal action/payload bytes, every truncation of the short payload, targeted malformed group/reference cases, multi-birth groups, transport-remapped action equality and aggregate-limit rejection. A deliberately framed but invalid-history case documents the boundary between decoding and later validation. These tests do not prove bootstrap, cryptographic composition, durable commits or the model's abstract before/after agreement.

Validation on 2026-09-13: `make -C tests run-swift-storage` and the same command with `SWIFT_STORAGE_TEST_FLAGS='-c release'` each pass all 31 Swift tests on this Mac. The ordinary-client type checker passes eight cases, including distinct action/origin and action/operation-index types. This increment changes no TLA+ transitions or application/UI code; it adds concrete byte checks beneath the models' abstract record-validation assumptions, not a new end-to-end proof.

### Bootstrap descriptors and initial snapshot

The codecs and independent fixtures below now run in `NVStorageCore`; see
[validation results](remaining-storage-validation.md). They authenticate/frame
their own bytes, not the complete bootstrap/history. The selected-store and
human-readable recovery-key encodings are also implemented there; actual
store activation remains a separate Runtime/Apple-adapter gate.

Descriptor header (150 bytes): ASCII `NVKEY1\r\n`, `u16(1)`, `u8(profile)`, collectionID, keyID, `u16(noteCodec=1)`, genesis SegmentLocator, `u8(kdfID)`, `u32(kdfVersion)`, `u32(memoryKiB)`, `u32(passes)`, `u32(lanes)`, 16-byte salt, 12-byte nonce, `u32(wrappedPayloadLength)`.

- Encrypted: profile 2, nonzero keyID, KDF 1 (Argon2id), version 0x13, 65536/3/4, wrapped payload length 32. Append 32 ciphertext bytes and 16 tag bytes: total 198. AAD is ASCII `NV key wrap\0v1\0` + the exact header; the plaintext is the 32-byte collection key. Preserve Encryption's normalization, nonce generation and KDF controls. A passphrase's explicit API byte length is **not** an extra prefix inserted into its Argon2 input.
- Public: profile 1, zero keyID/KDF/profile/salt/nonce/wrapped length; no wrapping bytes. Append SHA-256 of ASCII `NV public descriptor\0v1\0` + header: total 182. This is not authentication against an untrusted provider.
- Descriptor ID hashes the entire descriptor. It remains subject to the 16-KiB ceiling. No descriptor or payload ID grants physical association. Full independent encrypted/public fixtures and composition review are required before enabling these encoders.

Compute the initial commitment as SHA-256 of ASCII `NV initial values\0v1\0`, `u64(count)`, then `(birth, bytes(NoteValueV1))` entries in strictly increasing raw-birth order. Duplicates are invalid; empty initial collections have an explicit count-zero digest, never an absent commitment.

The first snapshot implementation supports **initial-import snapshots**, not arbitrary derived-history acceleration. A snapshot page (envelope kind 3) contains ASCII `NVSPG1\r\n`, `u16(1)`, importID, `u32(pageIndex)`, and a vector of birth-sorted `(birth, NoteValueV1, external import-operation reference)` rows with its locator table placed before the rows. References name the complete imported value and its containing action evidence, which the opener loads from history.

The root (kind 2) contains ASCII `NVSRT1\r\n`, `u16(1)`, importID, initialCount, initialValuesDigest, a locator table, an external ImportComplete reference, the represented operation frontier, then ordered `(u32(pageIndex), SegmentLocator, u32(rowCount))` entries. Frontiers sort by expanded operation ID. Page indices are contiguous from zero; concatenated rows are globally birth-sorted, counts/digest match the initial commitment, and every imported birth occurs exactly once. Empty import uses zero pages. Bounded pages can split a large initial collection; no row is split across pages. If one complete row cannot fit, decline the initial creation without altering the source.

Verify the initial provider snapshot by independently reconstructing the committed initial birth/value set from complete import history and comparing every row, reference and digest. The action/scope indexes are reconstructed from those retained action records before initial editability; this fresh-bootstrap path does **not** require repeating the full import read at each returning launch. [LocalStore](../LocalStore.md) defines indexed current-row startup; general provider snapshot acceleration remains deferred. Neither snapshots nor current rows grant pruning or cloud completeness.

#### Executable initial-import validation

`InitialBootstrapValidationV1.validate` takes the selected collection/profile/key,
decoded descriptor, exact snapshot-root locator and an exact-locator byte reader.
The caller obtains the protection context through normal unlock/recovery; it does
not let incoming envelope headers elect that context. The validator:

1. Checks descriptor collection/key binding and every object's complete envelope,
   kind and expected locator. Loads all root pages; checks page import ID, index,
   count and global birth ordering. The initial snapshot's operation maximum is
   ImportComplete alone: its ancestors are not additional maxima.
2. Walks the declared changes-object dependency tables iteratively, checks their
   exact operation/action indices and identities, and compares duplicate claims
   after semantic expansion. Equal repackaged claims count once; contradictory
   action metadata does not become a second interpretation of the same action.
3. Requires one unique Genesis in the descriptor's exact object and one unique
   completion, with matching supported profile, import ID, count and digest.
   The initial-only closure contains Genesis/Imports/ImportComplete; completion's
   ancestry covers every unique operation. Distinct Imports cannot create the
   same birth. Reconstructs and hashes the birth-sorted values from Imports,
   then compares every snapshot row and its exact import reference.
4. Validates each complete import action against its members' declared causal
   basis, excluding the group's own members. An observed earlier action must be
   observed as a complete group. Scope parents must equal **all** same-scope
   maxima in that basis, not a subset or the receiver's arrival-ordered history.
   Previous-origin references must have their exact origin and belong to the
   basis; they do not elect one winner between forked origins. Before is fresh
   absence and after is the exact unique imported value for that birth.

The result retains the selected descriptor, exact snapshot root, checked initial
rows, actions and required object locators. Each `InitialImportScopeFrontierV1`
binds its complete maximal action set to the collection, snapshot, completion
and scope used to derive it. Only the validator's source file can issue these
facts; a raw `Set<ActionID>` cannot substitute for one. Copying a fact preserves
its historical context, so a future consumer must check applicability to its own
context. The result is **not** accepted history, a local barrier, a pin,
a current provider catalog or physical-selection authority. Required descriptor
retention remains separate from its object-locator set. Do not activate a store
from this result alone or drop a known local tail that lies outside this initial
snapshot. A later Create/Put/Delete inside the inspected closure returns
`requiresGeneralHistoryValidation`, not partial success or corruption merely
because this narrower validator cannot reduce it. Missing input names its exact
locator; supplying it and retrying can succeed without rewriting any input.

This is synchronous worker/reference code with cancellation checks and iterative
walks, not the production resumable scheduler. It retains decoded bootstrap
evidence in memory; repeated ancestry queries can take superlinear total work,
without storing a quadratic transitive-closure matrix. Before connecting an
arbitrarily large bootstrap to Runtime, use indexed/sliced validation with the
specified work budgets and qualify memory/latency. No collection-size or history
cap is introduced, and healthy returning launch never calls this whole-history
validator. Cancellation yields no partial result or storage mutation.

Tests use real public/encrypted envelopes, an independently assembled complete
two-note/two-page fixture, missing-object/redelivery and cancellation sweeps,
wrong-but-authenticated commitments/pages, exact-reference failures, duplicate
and contradictory claims, complete/partial groups, concurrent scope maxima and
multiple scopes/groups within one object. See [completion evidence](remaining-storage-validation.md#initial-bootstrap-validation).
The [conformance audit](remaining-storage-validation.md#conformance-strategy-audit)
records which static boundaries and semantic checks are mutation-sensitive,
separately from pending Runtime consumer and durability tests.

### Private Local State

The implemented raw current-cell, authoring-context and empty-settings layouts are
frozen in the [Phase 2 record table](phase2-local-runtime-validation.md#frozen-private-record-layouts).
The current revision supplies the ordinary note predecessor; note and collection
scope frontiers remain separately represented. These codecs do not enable later
conflict/compensation or pending-file variants.

Use the required-state rows in [LocalStore](../LocalStore.md), not a separately
installed `NVLOC1`/`NVLST1` file or a nested private envelope. Schema-versioned
fields retain localStoreID, collectionID, profile/key/bootstrap binding, adapter
association, state generations, genesis/required-descriptor/retained-frontier
references and bounded independently versioned host settings. The first headless
caller supports explicitly empty settings and rejects unsupported nonempty
versions without rewriting them. This is not app-settings migration.

The opener receives positively validated adapter selection and an opaque database
key. Minimal external unlock/bootstrap representation and password-change policy
are a separate gate; the old file prefix is not an adopted shortcut. Database
authentication alone does not certify a copied physical association. Never put
the sole unlock secret in the database, or delete credentials because lookup
failed. Pending/item/reservation/receipt fields follow their existing semantic
contracts and need reviewed codecs before enabling those features.

Pin advancement and exact history acceptance commit atomically without replacing
unrelated newer settings. Counter exhaustion does not wrap. Required-state loss
or invalidation is not derived-row loss; a surviving pin still names required
retained closure even when a prior completion callback was lost.

## 4. Complete bootstrap and first recovery

This corrects the roadmap's previous deferral of **all** snapshot formats. Initial creation requires its complete snapshot; general provider snapshots remain deferred, while current-row startup is defined in LocalStore.

1. Under the existing explicit creation/owned-destination rules, capture the complete initial notes, birth IDs and source generations. Validate representability and compute the commitment before Genesis. Keep source inputs/credentials untouched throughout.
2. Allocate collection/key/import identity, writer epoch and action origin independently. Seal Genesis, then the bootstrap descriptor referencing its exact locator. Every retry reuses sealed bytes/allocated identities for that attempt.
3. Encode initial Imports as complete action groups in bounded segments, retaining exact origins/scope parents/before/after evidence. ImportComplete covers every batch and matches the Genesis commitment. No observer can activate a partial batch as an empty/smaller collection.
4. Construct and verify all initial snapshot pages and the final root, whose frontier includes ImportComplete. Nothing in Genesis/ImportComplete refers back to the snapshot's not-yet-created hash.
5. Validate and retain exact immutable objects/descriptors in the private database; commit their complete acceptance membership, ready work and retained pin atomically. Creation activates its private association only after the full bootstrap is verified. Stored-but-parked input is evidence, not bootstrap completion. SQL commit/recovery and final store activation replace per-object private file/pin installers.
6. Repository/profile setup and required plaintext outputs retain their independent activation gates. A headless private-store test does not prove a completed user-visible PlaintextFilesV1 creation or provider publication. Do not create application credentials or switch its collection for this test.
7. A fresh opener receives only the actual surviving database/journal, selected association and normal unlock input. Recover commits, validate bootstrap/known required evidence, drain actionable stored candidates and construct the current materialization. Returning startup uses indexed current-state catch-up; fresh bootstrap may read complete initial history. Never supply the test parent's expected values, acknowledgment log or prior process handles as recovery input.

For already established collections, an acceleration snapshot is not the only representation of independently retained valid import/action history. This does **not** permit ignoring a surviving pin naming a missing/corrupt accepted snapshot object: known-loss classification and exact repair still apply. Do not turn the **creation-completion** snapshot requirement into snapshot-only history authority. The existing bootstrap model allows reconstruction from complete initial history; it abstracts the concrete snapshot pin/installer and is not a proof of those details.

## 5. Small runtime/client contract

The following is an API design, not a shipped declaration or a public extensible backend framework. Implement the methods only with their actual issuer/adapter. Names are provisional; the contracts are not. Core owns values/validation; Runtime owns local storage and acceptance; the host owns its live model and pending generations. Apple adapters supply qualified rooted resources rather than redefining codecs.

| Method | Input/output contract |
| --- | --- |
| `LocalStore.prepareCreation(initial:destination:unlock:) async -> CreationOutcome` | Frozen full initial values plus explicitly owned destinations and normal secret inputs. Returns a retained creation session/typed failure, never “empty collection” on a failed read. Closure/pin acceptance and final application activation remain separate outcomes |
| `LocalStore.open(selection:unlock:) async -> OpenOutcome` | Adapter-validated selection and credentials; returns opened session + recovered values/frontiers, or locked/incomplete/unsupported/integrity/ownership failure. Returning startup reads valid current rows; known damage or invalid materialization has a separate recovery outcome |
| `session.persist(capture:) async -> CommitOutcome` | Immutable **already admitted** complete captures and exact host generations. Runtime retains ownership before any suspension; validates, seals once, atomically commits exact history/indexes/pin, returns exact covered generations and history receipt. Calling it is neither live admission nor provider publication |
| `session.retry(commit:) async -> CommitOutcome` | Store/session-issued pending commit handle; verifies the same sealed objects and latest compatible pin. Never accepts replacement note contents under that handle |
| `session.prepareReduction(input:) async -> PreparedModelChange` | Exact captured applied/live inputs and generations. No callback mutates live notes; the host publishes after synchronous final revalidation |
| `session.quiesce() async -> CloseOutcome` | Refuse new work, drain admitted captures, preserve failures and retained resources. Cannot report safely closed with pending admitted changes; cancellation returns to an owned live/failed state, not destruction of buffers |

Use immutable nominal values for `CapturedActionGroup`, `CapturedNoteGeneration`, `CommitHandle`, `AcceptedHistoryReceipt` and `PreparedModelChange`. No public receipt initializer, `markDurable`, backend-supplied success flag, `NSFileVersion`, Cocoa note object or arbitrary URL establishes authority. Methods return closed error classifications plus safe IDs/counts; no note/path/secret strings in general diagnostics. Adapter-native errors can be retained privately for the existing user-facing error handling.

The host freezes the capture before transfer, keeps its existing pending UUID/LSN sets and admits newer edits immediately while healthy. A returning completion lists exactly which note/action generations crossed the barrier. The host clears only those generations; it never reinstalls the old captured body. The first client is a headless in-memory owner, not a rewrite of NV's UI. Its expected-note test oracle must remain separate from the production reducer.

Runtime has one local owner/sealer and an independently owned provider lane. `persist` reservations serialize sealing and acceptance transactions; actor reentrancy cannot start a second sealer. No blocking filesystem operation executes on the main actor or cooperative executor. Reuse a small serial blocking-I/O adapter with separate local/provider resources. A slow provider accessor owns its buffers/handles until actually finished, even after a deadline or view dismissal. No general job scheduler is introduced.

An owned `receive` continues after two history-prefix interruptions: wait only
while a local save is active, using existing actor-isolated completion waiters,
then retry full validation. Recheck after each wake; an already-finished save needs
no notification. Cancellation/quiescing preserve owned inputs and the reservation.
Pending failed-save handles alone do not prevent progress. Other failure categories
remain explicit outcomes. Reopening recovers the durable ready queue.

`receivedObjectStatus(at:)` reports acceptance, pending validation, waiting, or blocked prerequisites
for an exact retained candidate. Blocked results include direct unaccepted locators
and deduplicated transitive rejected-root IDs/reasons. Descendants remain retained
and unaccepted until their own complete validation succeeds. Recording one object's
rejection atomically settles only its own queue/wait entries; crash/I/O failure
preserves either that complete result or retryable bytes. These diagnostics grant
no receipt, editing, or physical-file authority. See [tests](validation-resumption-results.md).

### Commit states and failures

| State/event | Required next behavior |
| --- | --- |
| Capture received | Retain exact inputs/IDs/generations and reserve the one in-flight local slot before awaiting work; newer captures remain distinct pending work |
| Seal succeeds | Store exact immutable envelope bytes in the owned commit; no caller can substitute content on retry |
| Acceptance transaction fails or completion is ambiguous | Keep exact sealed bytes and live pending generations; recover/query exact object/operation membership before retry. No acknowledgment from a reservation or partial SQL writes |
| Atomic history/index/pin commit succeeds | Issue the exact covered-generation receipt. Provider progress is independent; stale host completion must not clear a newer edit/Delete |
| Derived current-row transaction fails after acceptance | History remains durable. Catch up current rows before editable reopening; materialization failure cannot fail an otherwise durable quit |
| Waiter cancels after admission or completion callback is lost | Stop waiting, not owned persistence. Store retains admitted work; retry/recovery queries exact committed identities. Native task cancellation cannot mean undo or discard |
| Crash at any boundary | SQLite recovery selects complete transaction outcomes. Reconcile exact committed identities, drain persisted ready work and catch up materialization; no partial action, stale consent or callback-dependent history |
| Root/private store/lifecycle changes | Fence effects against their actual context. Root loss alone does not cancel healthy local acceptance; private-store/ownership/key loss blocks local success |
| Close fails | Return a still-owned pending session and explicit failure/recovery choices. No fallible work in deinit or termination callbacks |

Method completion can be delivered once to a live waiter, but the protocol makes no exactly-once callback promise across process death. Logical idempotency comes from identities, exact installed bytes and recovery. A cancellation result must distinguish “not admitted” from “admitted work continues/failed”; it cannot ambiguously release the sole recovery buffer.

## 6. Tests and next implementation gate

Current command: `make -C tests run-swift-storage` (native Swift Testing; no app/simulator; initial dependency resolution downloads the pinned packages). Literal scalar and complete-note fixtures cover exact composed/decomposed spelling, case-distinct labels, NUL/CRLF, malformed UTF-8, every truncation point, trailing bytes, attacker-sized prefixes, finite date precision and invalid/noncanonical dates. Operation fixtures independently specify canonical preimages, hashes and transport bytes for all six implemented kinds. They check semantic-field changes, local/external/table remapping, stale local-reference contexts, preserved unresolved external claims, and record sizes below/at/above the 64-MiB ceiling. These tests use ordinary public import, not `@testable`; they do not qualify whole-action admission or an OS persistence primitive.

After building the package, run `python3 tools/test-swift-storage-types.py --modules <build-bin-path>/Modules` from the repository root. Obtain that bin path with `swift build --package-path NVStorage --show-bin-path` using the same scratch/configuration options as the build. The script checks an ordinary client first, then requires specific compiler rejections for action/segment-versus-operation identity, causal parents versus note predecessors, identity reassignment and a forged claimed-ID constructor. An unrelated import/compiler error does not count as a passing negative control.

The ordinary local save/reopen slice is now implemented and tested in the
[Phase 2 report](phase2-local-runtime-validation.md). Before expanding it to the
complete storage engine:

1. Extend the ordinary validator/reducer to concurrent/derived Current, conflict preservation and portable compensation. Keep the existing semantic/transport/bootstrap/ordinary fixtures. Exercise actual legacy label-token capture independently of the case-insensitive UI index during application bridging.
2. Qualify the implemented envelope/descriptor crypto composition and remaining platforms. Preserve AAD/KDF/header, wrong-context and exact compressed-stream tests. No cleartext encrypted-profile scratch files.
3. Extend the [ordinary-history scheduling/isolation checks](phase2-hardening-validation.md) to large bootstrap/imports and later reducers; qualify the adopted zstd physical codec and final selected-store activation. Preserve acceptance/ready/pin/VFS/second-crash tests and the indexed [fast-start contract](../LocalStore.md).
4. Extend the now-tested E barrier → held completion → newer F edit/Delete schedules through actual application capture and publication, including the later provider/undo adapters. Recovery continues to receive only surviving files and normal unlock inputs.

The source's label behavior was checked directly in [LabelObject](../../../LabelObject.m) and [NoteObject](../../../NoteObject.m); Unicode default case conversion is distinct from case folding in the [Unicode SpecialCasing data](https://www.unicode.org/Public/15.0.0/ucd/SpecialCasing.txt). That reference illustrates why neither operation should be silently introduced into stored-value identity. The existing [model coverage](../../tla/README.md) supplies bounded semantic/crash obligations, not a codec or filesystem certificate. Do not change an assertion to accommodate a faulty encoder/installer.

### Validation checkpoint — 2026-09-10

- Swift 6.3.3 on the arm64 development Mac: 20 native Swift Testing tests passed in debug and optimized builds, including six parameterized operation fixtures and complete-value/operation sizes one byte below/at/above the existing object ceiling. The ordinary external client compiled; five invalid clients produced their intended diagnostics. The legacy app still builds. No Linux, Intel or actual macOS 11.5 execution is claimed.
- An isolated production-source mutation changed u64 writing to little-endian. The literal date and complete-note fixtures failed on their expected byte comparisons; this was a real assertion failure, not a compiler failure. The mutation is not present in the package.
- A second isolated source mutation hashed causal parents in place of note predecessors. The semantic-field test failed three assertions because changing only supersession no longer changed identity. No fixture/assertion was weakened; the mutation is absent from the package.
- Existing `check-history-rules.py` passed its scalar/edit/compensation corpus. The unchanged `bootstrap-` TLC family produced four exhaustive positives, seven designated mutation counterexamples and three reachability witnesses. TLC's local listener required execution outside the sandbox; the denied attempt was not counted as a model result.
- An additional unchanged `merge-` model rerun was unnecessary for this codec-only increment: it checks no Swift bytes or implementation trace. `merge-third` and `merge-dominated` exceeded that run's 60-second per-case limit; the other checks matched their expected outcomes. These timeouts are not passes or counterexamples, and no further model rerun is needed to finish this increment. Existing model evidence remains separate from the new codec tests.
- These checks do not establish encryption, complete action/segment or graph validation, snapshot truth, installation, pin durability, runtime API implementation or cross-machine storage conformance. Those remain the next gates above. No TLA+ assertion was weakened or changed.
