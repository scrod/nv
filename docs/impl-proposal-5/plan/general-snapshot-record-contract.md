# General snapshot records and retention coverage

Status: executable-format contract with [durable local acceptance](phase4-snapshot-acceptance-validation.md)
and [retention coverage](phase-4-improvements/snapshot-retention-coverage.md).
Initial bootstrap roots/pages keep their existing layouts. The [Phase 4 plan](phase4-startup-recovery-plan.md) and
[data-safety scenarios](phase4-data-safety-contracts.md) govern qualification.

## State and history responsibilities

A general snapshot describes one complete operation-ancestry cut. Its canonical
stream contains seven ordered record classes: full live current cells; maximal
operation occurrences; all action-scope maxima; deleted-birth/Delete occurrences;
typed deterministic retirements; copied-source dispositions; and restoration
index entries. Current cells reuse their canonical note/reference encodings,
including represented heads, derived state and automatic/conflict identity.

The eighth category contains exact **retention-parent** snapshot-root locators.
These preserve accepted object closure independently of the seven logical state
categories. They neither enlarge the represented operation cut nor select a
reconstruction winner. An old logical cut may cover a newer snapshot's objects;
reconstruction still unions every accepted outside-cut operation. An empty parent
set has an explicit zero count in the same v1 layout. Initial-bootstrap encodings
and public Runtime methods remain unchanged.

This is the single current, unreleased general-snapshot format. NV's last public
release was in 2011 and used epoch-4 Notes & Settings; compatibility covers
epoch-4 opening, recovery and explicit export. Superseded development snapshot
layouts have no compatibility decoder or migration path.

The exact retained operations/actions remain authoritative for ancestry,
before/after values, origin provenance, compensation chains and historical
bodies. Undo/Redo and history queries reconstruct these from retained records.
The snapshot adds no executable undo objects, consent or physical file receipts.
Collection action maxima are the collection-scoped entries of the scope class.
Deleted births can have multiple Delete occurrences. Restoration entries identify
the source birth, deletion action, restoring action and newly created birth.

Both profiles use the existing envelope kinds/protection/zstd rules. Public hash
integrity and encrypted authentication remain different guarantees. Complete
page assembly is preview evidence; semantic verification against accepted history
is a separate Runtime issuer. Neither supplies a durability receipt or permission
to install a view. Verification against not-yet-accepted history remains
subsequent integration work. Local acceptance consumes a separately issued
checked batch and returns a snapshot-specific durability receipt.

## Bounded tree and canonical stream

Each page uses the `snapshotPage` envelope kind. Data leaves contain byte ranges
of a single canonical stream. Index pages contain contiguous child-range
references. Root/page locators are exact existing `SegmentLocator` encodings.
The root names one tree, whose transitive closure names the complete page set.
This keeps the root fixed-size and permits growing manifests/frontiers/indexes
without a collection-lifetime count limit. Traversal is iterative; pages carry no
back-reference to their root. A record may span leaves. Only an individual record
payload and individual page are subject to the 64-MiB decoded-object ceiling.

All integers are big-endian. Decoders require complete consumption, checked
arithmetic, canonical order and exact ranges/counts/digest. The default writer
uses 256-KiB data chunks and fanout 128; these affect transport only. Bounded
alternative chunk/fanout choices must yield the same state stream.

| Record | Layout |
| --- | --- |
| Page range | locator(56), first byte offset(u64), byte count(u64), positive/nonoverflowing range |
| Data page | `NVGPG1\r\n`(8), version(u16=1), tag(u8=0), first offset(u64), payload length(u32), payload |
| Index page | same magic/version, tag(u8=1), child count(u32), ordered range references(72 each) |
| Root | `NVGRT1\r\n`(8), version(u16=1), reducer(u16=1), initial-bootstrap snapshot locator(56), tree range(72, offset zero), eight record counts(u64 each), state digest(32) |
| State stream | `NVGST1\r\n`(8), version(u16=1), then records: tag(u8), length(u32), payload |

The root is 236 bytes, including when the retention-parent count is zero. State
digest is SHA-256 over UTF-8 `NV general snapshot state\0v1\0` followed by the
entire canonical stream. Root counts correspond to tags 1–8 below. The operation-frontier class is nonempty;
even a zero-note initial collection contains Genesis/ImportComplete history.

| Tag | Payload | Strict ordering key within class |
| --- | --- | --- |
| 1 | canonical `CurrentNoteCellV1` bytes | birth |
| 2 | `StoredOperationReferenceV1`(92) | operation ID |
| 3 | scope(tag 0 collection; tag 1 + birth for note), `StoredActionReferenceV1`(76) | scope bytes + action ID |
| 4 | deleted birth(16), Delete occurrence(92) | birth + operation ID |
| 5 | canonical deterministic-conflict identity(33/41) | identity bytes |
| 6 | copied-source operation ID(32) | operation ID |
| 7 | source birth(16), deletion action ID(16), restoring action ID(16), new birth(16) | full payload |
| 8 | exact retention-parent `SegmentLocator`(56) | full locator bytes |

Tag 8 is canonical, strictly increasing and duplicate-free, including when a
record spans page boundaries. Its separate count supports arbitrarily wide
captured root frontiers through the existing bounded pages. Roots, pages and
streams all use version 1.
`GeneralSnapshotRecordV1` remains the seven logical classes;
`GeneralSnapshotPreviewV1.retentionParents` retains category 8 separately.
The Swift family names and `encodedV1`/`decodeV1` entrypoints describe this one
layout. The writer accepts an empty or populated retention-parent set; its wire
layout, category count and digest domain are fixed. Decoders reject unsupported
root/stream/reducer versions and incomplete count vectors explicitly.

References are full external occurrences, with existing role widths. Every
claimed occurrence must resolve to its exact accepted envelope/index/ID before
semantic verification succeeds. Transport aliases may use different valid
occurrences of the same logical operation/action; semantic comparison uses their
logical identities and independently verifies their addressing.

## Issuance and failure boundaries

- Plain decoded root/page/record values are claims. Their constructors check
  structural invariants and wire bounds.
- `GeneralSnapshotPreviewV1` has an issuer-restricted initializer. Its reader
  verifies every exact envelope, complete tree/stream, canonical record order,
  root counts and digest. It retains the exact page inventory and named history
  locators directly present in records/the bootstrap field, and the independent
  retention-parent locators. `requiredLocators` combines these dependency sets;
  `historyLocators` names the logical-cut inputs. The semantic verifier
  additionally resolves the full represented ancestry. Missing input identifies
  its exact locator; incomplete data cannot
  produce a preview.
- Runtime verification captures a positively owned accepted prefix, reconstructs
  the claimed operation cut and checks complete action membership, exact
  references and every state/index claim. `VerifiedGeneralSnapshotClaims`
  construction is confined to that verifier and binds collection/store/session/
  checked prefix. The root/pages are optional external assembly input at this
  stage; their acceptance and pin coverage are separate integration steps before
  a recovery-installation consumer can use a durable snapshot basis.
  On this exceptional path, it audits the full accepted graph index against
  actual accepted Changes envelopes. Discovered missing indexed membership is
  required-history damage, preserved through the existing damage/reopen path.
- `GeneralSnapshotCapture` freezes the accepted snapshot-root frontier with its
  accepted prefix. File-private `CheckedRetentionParents` validates each exact
  supported accepted parent root, its seal/hash protection, collection, kind and
  locator. The acceptance consumer checks issuing connection/store/prefix and
  rechecks the exact sealed root bytes. Already validated parent closure is reused
  without recursive ancestor traversal. Missing parents use the existing
  accepted-history wait; unsupported/rejected parents block the child without
  rejecting it. Parent roots must precede the child's acceptance.
- Optional snapshot construction emits bounded objects incrementally through a
  caller-owned sink. A sink completion is transport output, not local acceptance.
  The production sink retains exact candidate bytes incrementally. Complete local
  acceptance separately commits root/pages, edges, pin coverage and wakeups in the
  existing history transaction. Parent edges advance only the named covered tips;
  independent concurrent roots remain. Exact duplicates leave membership unchanged.
  See the S1 report and retention-coverage report for retry and recovery ordering.

Old snapshots remain retained and valid for their original cut. Later accepted operations must
be unioned before current-view installation. Healthy current-row startup retains
its existing indexed path. No new persistent table, proof cache, pruning policy
or provider freshness assumption accompanies this format.
