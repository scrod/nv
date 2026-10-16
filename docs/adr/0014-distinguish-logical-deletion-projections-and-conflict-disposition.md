# Distinguish logical deletion, plaintext projections and conflict disposition

Status: accepted.

Implementation correspondence: the [P6.1 history/observation contract](../impl-proposal-5/plan/phase6/03-history-observation-contract.md)
separates Runtime-checked intended output from passive persisted accepted-file
descriptions. It preserves complete source references when optional stamping is
omitted, and requires a later fresh rooted receipt to advance accepted output.

Explicit causal Delete operations, not file absence or checkpoint omission, convey intentional deletion. A Delete observing an edit removes the birth; a concurrent unobserved edit is preserved under a deterministic conflict birth. Restore/undo deletion uses fresh identity, and same-birth Put after Delete is invalid. Retained operation history preserves ordinary deletes and typed conflict retirements; syncServicesMD and UUID version bits alone supply no modern semantics.

Coverage is evaluated against all applicable Deletes, not per-Delete copy unions. If D₀ is concurrent with E but E precedes D₁, the source remains absent and an untouched derived E copy is retracted when D₁ arrives. F extending E concurrently with D₁ remains preserved. Mere display/projection/materialization never commits a recovery or retirement; independent user edits/explicit copies remain protected, including during pending admission. Same operation history gives the same final live/conflict state regardless of arrival order. Retraction neither erases history nor authorizes physical cleanup.

Unexplained external absence uses the existing confirmFileDeletion preference on either Mac. With confirmation enabled the logical note remains pending choice; a committed Delete bypasses that prompt because it records an NV command, not because it is remote. Confirmation disabled permits admission under that preference. Revalidate pending choices when files/notes/history change. Only the original exact-snapshot physical deletion runs after local durability; no filename/hash/xattr/tombstone sweep or permission replay after crash.

The [P6.2 live-permission boundary](../impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#original-local-delete-permission--internal-implementation)
captures the accepted physical source before local Delete admission, then checks
the exact local command receipt and complete accepted action. Its typed inputs
expire with the original store/root ownership. The internal consumer commits a
required-private source-attempt record before coordinated protected capture, compares
the complete original snapshot and preserves uncertain results. Restart can
inspect its retained location under fresh context; final source accounting and
owned cleanup remain separate gates. The record retains recovery inputs rather
than replayable physical permission.
The accepted physical observation includes a compact commitment to complete raw
metadata. Original-Delete capture and replacement compare it before effect;
coarse stat equality alone cannot hide changed tags, encoding, permissions or
creation time. The commitment describes a local state and leaves original-operation
identity lifetime, source accounting and fresh publication as separate checks.
The live original-Delete capture rereads coherently and retains that exact read
descriptor through removal. A shared, file-confined resource owner closes it
on final release. Native preflight verifies the borrowed descriptor; failed or
cancelled capture releases it. Root/session invalidation still fences effects,
and restart recovers inspection evidence only. This establishes the capture-to-effect
pin for this consumer. Original-source removal consumes that same live capture
and exact durable attempt under fresh file/root checks. It captures the actual
public source into protected storage and independently observes/preserves any
raced occupant. The required attempt record and byte owners remain intact for later
P6.4 accounting/settlement. Restart yields inspection only, including when cleanup
already removed the artifact. The [physical contract](../impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#owned-original-source-cleanup)
records a confirmed last-check/unlink counterexample against the earlier public
unlink candidate. The replacement captures the actual artifact into a protected
persistent directory derived from the same durable attempt, then compares it
before private cleanup. Mismatches restore exclusively or stay recoverable;
fresh recovery inspects both locations without recreating permission. This
boundary requires its own ownership/privacy and crash qualification; UUID uniqueness
does not authorize deleting a replacement at an already observable backup name.
The specification's no-foreign-removal requirement is unchanged.

Active-presenter checks require one logical deletion accessor: capture
the original filename directly into protected storage, compare it, and remove
only the matching child before returning. Recovery names stay implementation
details; announcing them as logical moves can redirect an external editor's
later save. Ordinary content safe saves use update coordination, while genuine
public renames retain move notifications. The direct Runtime consumer replaces
the two-step capture/cleanup bridge. Its receipt binds the existing original
descriptor-lease identity, and an owned directory surviving failure keeps its
durable attempt. Pre-capture candidates retire only when they created no owned
directory. These concrete ownership checks preserve causal Delete, durability
and recovery-only inspection semantics.

Plaintext files remain current editable projections. Double catalogs and root/model fences guard their decisions; optional filesystem IDs have only documented local scope. A bounded fixed-name projection stamp stages collection/birth/revision/locator/format/exact-byte provenance with NV outputs where supported. It can identify a missing segment and avoid duplicate import, but it is not authoritative UUID metadata or a simultaneous body/metadata-delivery contract. Verify its references against history; copied/stale/malformed/foreign claims receive specific conservative handling. Established applicable associations/handoffs and unique represented states remain automatic.

Exact non-UTF-8 output stays in [required private captured-byte records](../impl-proposal-5/plan/phase6/09-exact-output-contract.md),
committed with its intent. Native encoding availability and Unicode conversion
do not establish cross-host byte reconstruction; recovery uses the captured bytes
and verifies their digest. This adds no synced sidecar or physical authority.

Portable descriptions use the [optional Changes section](../impl-proposal-5/plan/phase6/08-portable-projection-contract.md)
with complete external source bindings and accepted dependency retention. This
preserves wide provenance when the bounded stamp is omitted. Description bytes
affect their enclosing envelope identity, while note/action identities and Current
selection remain independent. Receipt of a description records no local physical
installation and emits no echo edit.
The [complete source reader](../impl-proposal-5/plan/phase6/10-complete-binding-query-contract.md)
checks that provenance beyond the optional stamp's size limit, while its owned
output consumer separately checks exact encoded bytes and current private
generation. Both preserve the distinction between historical contents and live
physical applicability.
The [local producer](../impl-proposal-5/plan/phase6/11-projection-producer-contract.md)
freezes its historical description once and reuses the existing durable receive
queue across retry/restart. A newer edit or intention does not change the frozen
description or let its completion clear that newer work.
Each producer capture also covers the accepted Changes tips through authenticated
dependencies. Acceptance rechecks those parents and advances the existing frontier
atomically, preserving concurrent tips and all older bytes. Retention coverage is
independent of the binding's represented note revisions.

The serialized per-note file transition also has a distinct private frozen-output
owner. It preserves its captured source and exact bytes while newer intentions
change. Intent switching releases only chunks absent from all accepted, intended,
source and frozen owners in that same private transaction. Note-scoped chunk keys
keep that check local; future physical settlement must transfer remaining ownership
before clearing the frozen record. See [the ownership contract](../impl-proposal-5/plan/phase6/13-frozen-output-contract.md).

The [P6.2 replacement reservation](../impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#durable-replacement-candidate-reservation)
records the candidate backup location and exact frozen transition in required
private state before entering a physical replacement. It preserves a recovery
inspection target across interruption; its historical description does not
certify an installed file, confer cleanup permission or clear newer intentions.

File installation checks requested dates at the supported filesystem's documented
precision, while logical history preserves the original values. HFS+/HFSX's
whole-second representation is qualified during staging and checked exactly at
installation. Body and mandatory metadata receive final readback; coarse change
timestamps alone do not establish that an output stayed unchanged.

The [private settlement mapping](../impl-proposal-5/plan/phase6/14-settlement-record-contract.md)
keeps consumed-input acknowledgment distinct from a completed projection receipt.
Full decision identity survives preview release. A completed B advances accepted
ownership while newer C remains intended with B as source; only the fresh rooted
consumer may publish that passive calculation.

Automatically import ordinary eligible unassociated files after mandatory availability/provenance checks unless a plausible live repair candidate exists. A candidate must itself need relationship repair and match the file's active path or exact nonempty active projection bytes. Known placeholders, temporary unreadability, initial writes still owed and incomplete root scans are not lost relationships. Active comparisons include the current concrete intended output and the last accepted representation only while its save/rename/format transition remains unfinished. No arbitrary history, timestamps, similarity voting, pooled evidence or healthy-note candidates recreate blanket confirmation. FSEvents history only prioritizes normal inspection; it neither adds questions nor unconditionally restarts attempts.

Association is an explicit repair of a live birth, not implicit content replacement. Preserve current and file inputs, use trustworthy-base reconciliation or explicit content review, and coordinate the note's missing-file decision. Import as New remains fresh; dismissing review means decide later. Known deleted provenance requires fresh restoration/import, not resurrection or unlink. Quiet catalogs do not prove global newness: tolerate independently admitted late duplicates while retaining their identities and work. Retrying one import instead reuses its reserved identity and recovers its durable operation before rescanning.

Retain one latest verified pending-file snapshot in private Application Support, durably switching its Local State reference before releasing the previous one. Pin exact admitted-operation inputs independently of later previews. Missing/unreadable sources retain the last readable bytes; retention grants no automatic import or physical authority. Pending snapshots are not provider history, disposable cache, or a new WAL. Ordinary close/root switch/private repair preserves them; uncommitted reservations are never replayed consent. [The protocol](../impl-proposal-5/Protocol.md#pending-file-retention-and-retry-identity) specifies the crash/receipt ordering and loss boundary. There is no provider sidecar or xattr dependency in encrypted mode; deterministic path-slot co-add remains disabled.

Ordinary edits target only Current's represented revisions. Causal awareness of an unresolved alternative does not supersede it, and editing one note never rewrites separate conflict notes. Derived merge/equal-value Current already represents its named inputs. Explicit resolver choices, not general mutation admission, carry the scope that resolves alternatives.

The [private commit/recovery contract](../impl-proposal-5/Protocol.md#pending-file-commit-and-recovery-records) separates provisional relationship claims, note durability and final file receipts. A neutral repair creates no echo action; keeping Current can nevertheless require a safe physical write. A Delete invalidates a pending association, not already-admitted operation durability. Exact Import history settles an observation even after that birth is edited/deleted; an absent receipt or live note never alone justifies another Import. Private reference cleanup preserves every still-recoverable metadata generation. Accepted output advances only after exact verification/source accounting; B may replace accepted A while intended C stays pending, without clearing C or allowing a later rollback.

The badge-invoked resolver swaps a separate read-only NSTextView-equivalent for LinkingEditor without overriding persistence. Current is frozen live text; selection asynchronously previews exact captured NV or Apple input. Distinguish the two sources. Use this version applies only body through ordinary admission and covers captured NV heads; Save as new note uses the stable body-only key/slot, exact candidate checks and selected-revision disposition. Current has no Save action. Modified/deleted/retired candidates are never overwritten on retry.

For Apple versions the extra gates are exact segment/action/parent durability, exact plaintext-file installation and coordinated source/member/root/generation revalidation using WritingForMerging. Use resolves applicable captured members; Save only the selected one. New members remain unresolved. No NSFileVersion replacement/removal, all-version enumeration, upload gate or persisted Apple intent/identifier ledger. A fresh successful unresolved query alone settles Apple's badge; NV-head conflict state is evaluated separately.

Close × remains available through every per-item wait/error. Dismissal restores the unchanged editor and permits background completion only while evidence remains valid. Finite passes park exhausted work; re-presentation automatically retries parked applicable items without duplicating running accessors. There is no Retry or initial Merge button. Stale choices never re-admit over newer text; local durability suspension is an independent global gate. NV's historical dispositions survive via operations; Apple handles/physical authority do not.

NV-head Save as new note is representation-only: preserve the chosen revision separately and remove only its completed conflict-attention entry. It does not also Keep Current or author a source Put/Delete. Source heads, normal deterministic Current selection and temporary local-edit fencing are independent of copy dispositions. This keeps copying distinct from choosing the original's body and avoids competing implicit source choices. Reciprocal copies may leave duplicate contents in the original and recovered notes; an empty unresolved list never makes the original absent. Completed dispositions survive later copy modification/deletion, while uncopied/new descendants remain reviewable. Apple's selected-member behavior is unchanged.

Rename/update accounts for its captured source and verified destination
independently. A retained backup, restored source and late public occupant each
keep their own contents and observations. Case-only spellings may resolve to
the same newly installed file; source accounting uses the original captured
identity instead of treating every old-spelling occupant as the original.
NV sends the final public move notification. A peer's retained case-equivalent
URL is acceptable only when actual file identity and its subsequent save still
refer to that intended file. See the [native relocation mapping](../impl-proposal-5/plan/phase6/15-rooted-mutable-files-contract.md#native-renameupdate-candidate).

The concrete Swift bridge commits the same existing per-birth candidate slot
before replacement or relocation. Distinct live permission and recovery types
enforce the operation's role. Read-only restart inspection preserves every named
stream and the frozen byte owners; final accepted-state advancement and artifact
release still require checked source accounting. Native output and fresh Swift
readback both verify complete metadata in the filesystem's qualified precision.

Normative requirements: DELETE-01, DISC-01, PUB-01, REC-01, WAIT-01, HIST-01, IMPORT-01.
