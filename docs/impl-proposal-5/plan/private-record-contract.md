# Required private records: version 1

Status: codec/transaction implementation contract, 2026-10-05. Qualification is
recorded separately in the Phase 4C–4E report. These records live inside keyed
private SQLite pages; they are passive claims until their owned consumer checks
scope, complete references and expected generations.

## Host inventory

| Existing source | Modern owner / representation |
| --- | --- |
| `NotationPrefs.notesStorageFormat`, `secureTextEntry`, `confirmFileDeletion` | Versioned collection settings: unsigned format value and booleans |
| `baseBodyFont`, `foregroundColor` | Bounded passive platform representations with explicit host codec versions |
| `pathExtensions[4]`, `chosenExtIndices[4]` | Four ordered extension groups with exact UTF-8 spellings and checked chosen index |
| Remembered note cursor ranges | Birth-keyed UTF-16 anchor/length values; host rechecks against displayed text |
| `storesPasswordInKeychain` | Local remember-unlock preference; usable credentials retain the existing descriptor/adapter contract |
| `GlobalPrefs` application/window/search defaults | Existing application-global owner; host explicitly maps collection overrides |
| Root bookmark / observed file information | Passive versioned association/observation bytes; fresh physical validation is required |
| `epochIteration`, salts/verifier/key lengths, `syncServiceAccounts`, old Keychain identifier, volume UUID | Epoch-4 host import/compatibility inputs; cipher context comes from the validated descriptor, and old service/volume identities supply no modern authority |

All integers are big endian. All variable byte fields have UInt32 length prefixes
and the existing 64-MiB decoded-record ceiling. Counts are checked against remaining
bytes before allocation. Unknown record/version/field tags are unsupported;
malformed supported records are integrity failures. Empty settings codec 1 remains
explicitly supported; nonempty settings use codec 2 and the record below.

## Encodings

Settings: `NVSET1\r\n`, UInt16 version 1, UInt32 field count; fields in strictly
increasing UInt16 key order, each followed by its fixed key-specific value.
Keys: 1 storage format UInt64 (0…3), 2 secure entry byte boolean, 3 deletion
confirmation byte boolean, 4 base font and 5 foreground color (UInt32 platform
codec > 0 and length-prefixed bytes), 6 extension groups (exactly four; each
UInt32 text count, length-prefixed UTF-8 strings, UInt32 chosen index),
7 cursors (UInt32 count; sorted unique birth16, anchor UInt64, length UInt64),
8 remember unlocking byte boolean. Cursor range arithmetic must not overflow.
Missing settings fields mean no stored override, not permission to reset existing
fields during repair. Replacement writes a complete captured settings group.

Association: `NVASC1\r\n`, UInt16 version 1, association16, collection16,
local-store16, descriptor32, UInt32 bookmark codec > 0, length-prefixed bookmark.
The original binding is historical evidence during repair; the new store binding
is established explicitly. Decoding supplies neither ownership nor access rights.

Retained capture scope: a `private_groups` key of UTF-8 `repair-source/` followed
by the original local-store16, with generation 1, codec 1 and payload
`collection16 || descriptor32`. Repair preserves these existing bindings from
every contributing private source, including bindings inherited from an earlier
repair. The descriptor must belong to the completely validated retained union.
Identical records coalesce; contradictory records leave repair incomplete.
Malformed framing/collection is an integrity failure, an unsupported codec remains
unsupported, and a missing required descriptor leaves repair incomplete. The
binding lets existing pending-record readers verify historical capture context;
fresh observation and consent checks still govern external effects.

Pending snapshot: `NVPAY1\r\n`, UInt16 version 1, snapshot16, collection16,
source-store16, descriptor32, presence byte (1 present, 2 absent, 3 unreadable),
length-prefixed exact path UTF-8, UInt32 observation codec > 0,
length-prefixed passive raw observation, length-prefixed exact source bytes,
length-prefixed canonical `PlaintextNoteValue`. Raw observed bytes/presence stay
distinct from decoded defaults. The snapshot remains immutable and independently
referenced by latest and frozen owners.

Reservation: `NVRSV1\r\n`, UInt16 version 1, reservation16, snapshot16,
decision byte (1 automatic Import, 2 explicit Import, 3 changed association,
4 neutral association), target birth16. Changed decisions carry operation32,
nonce16, action16 and canonical result digest32. Neutral decisions carry SHA-256
of `"NV pending Current\0v1\0" || complete canonical Current cell` and its canonical
note-value digest (32 bytes each). This binds revision, note/action references and
complete values while keeping historical bodies in their existing durable owner.
The consumer checks both digests against the freshly checked Current. The named source snapshot is
the frozen input. Reservation identity and exact values survive retry;
reservations never constitute replayable consent. After complete acceptance,
the operation consumer checks actual kind, birth, nonce, action, value and closure.

Pending table roles hold item16, positive signed generation, latest snapshot,
reservation references, classification status and settlement links. Large payloads
and reservation encodings live in rowid BLOB tables; small item/reference/settlement
rows use indexed identities. Receipt settlement transfers the observation link
atomically before releasing its frozen reference. A committed operation's identity
remains settled even after its birth is edited/deleted. Physical association
observations are passive, generation-bound receipt data and need fresh validation.

Independent fixtures specify complete bytes, field participation and malformed
neighbors. Schema constraints complement semantic consumer checks. Every private
transaction preserves the unrelated accepted-history pin and other private groups.

## Concrete admission and repair consumers

Re-review of an uncommitted item/snapshot reuses its reserved birth and records
fresh action/nonce/reservation inputs. The replacement advances the item's
generation in the same transaction; an older prepared capture fails its binding.
Complete committed operation evidence or an owned ambiguous sealed commit keeps
its exact identity and forbids renewal. A committed birth's later edit/Delete
changes Current rather than undoing its Import evidence.

Settlement checks the expected item generation before presenting the snapshot to
the controlled observation consumer, then repeats the check inside its reference
transaction. Neutral settlement additionally requires supported current rows
covering the actual accepted prefix, a live target, and both reserved Current and
value digests. A failed materialization leaves the item retryable until catch-up;
an already accepted Delete cannot settle against the old row. Completion clears
the latest reference only if it still names this frozen snapshot.

Complete backup compares a transient streamed fingerprint of all four pending
tables and raw view metadata against its captured read cut before normal opening.
Opening then processes captured ready work or rebuilds derived rows under ordinary
validation; later source writes remain outside the copy. The result's `through`
names the source cut, independently of that recovery progress. Repair copies complete coherent private
reference groups, retains historical source scopes explicitly and establishes the
new store association. Failed component scans produce a scoped partial salvage
outcome with preserved working evidence. A complete replacement requires every
known required object and complete private link before fresh opening/activation.

Wrappers retain `unlock/<descriptor-hash>.nvkey`; history-preserving repository
copy uses the existing `NV Data/v1/keys/` and writer-scoped `segments/` grammar.
Partial salvage, a repository-copy result and decoded selected-store bytes each
describe their own scope; verified selection consumes separately issued evidence.
