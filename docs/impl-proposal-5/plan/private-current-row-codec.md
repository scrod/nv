# Private current-row codec and locality operations

Date: 2026-10-07. Byte contract for Phase 4F. Logical values remain
`CurrentNoteCellV1`; this framing is used only inside the private database.

## Cell frame V1

All integers are unsigned big-endian. A decoder consumes the complete input.

| Field | Bytes | Rule |
| --- | --- | --- |
| Magic | 8 | ASCII `NVROW1\r\n` |
| Version | 2 | `1` |
| Encoding | 1 | `0` raw, `1` dictionary-free zstd, `2` dictionary zstd |
| Expanded length | 4 | Length of the complete canonical cell; 1–64 MiB |
| Stored length | 4 | Exact remaining payload length; 1–64 MiB + 64 KiB |
| Dictionary digest | 32 when encoding=2 | SHA-256 of exact dictionary bytes |
| Payload | stored length | Canonical cell or exactly one regular zstd frame |

The raw `NVCEL1\r\n` magic remains independently recognized for the active
raw-canonical startup benchmark and equal-prefix stale-layout control in
`CurrentStartupBenchmarkTests` and `CurrentRowStorageTests`. Those controls
install canonical cells through their test SQL seam; ordinary production writers
emit `NVROW1` frames, including encoding 0 for raw payloads. After a magic is
selected, failure is returned without trying another interpretation. The
canonical cell decoder still checks birth, complete value, references, provenance
and ordering.

Compressed frames have a known content size equal to the expanded length, a
window of at most 64 MiB, and exactly one fully consumed regular frame. Reserved
header bits, skippable frames, unknown sizes, concatenation and trailing bytes
are rejected. Dictionary-free frames carry dictionary ID zero. Dictionary
frames carry the ID of the exact full-digest-bound formatted dictionary; the
short frame ID is an additional check, never the lookup key.

Writers compare complete framed sizes at level 3: raw, dictionary-free, then
dictionary compression. A tie keeps the simpler representation. Resource
failure of optional compression permits valid raw output. Logical validation,
SQL errors and a failed current-state fence retain their ordinary outcomes.
Provider envelopes continue to use the separate dictionary-free profile.

## Dictionary role and schema

Private schema revision **2** introduced `current_dictionaries`: ordinary rowid storage
with a unique 32-byte digest and immutable formatted dictionary bytes, bounded
to 8 KiB. Exact digest/format checks occur when a dictionary is used. Inserts
compare existing bytes before reuse; replacing a dictionary is forbidden.
The later [startup/scoped-query increment](phase-4-improvements/startup-and-scoped-queries-validation.md)
adds the conflict-copy index in current schema revision **3**. An otherwise
complete superseded development schema returns `unsupported` and remains
preserved. Missing required tables/header state retain the existing `incomplete`
outcome; neither outcome initializes over the input. New candidates initialize
the current revision 3. This unreleased private revision creates no legacy or
mixed-writer compatibility promise.

Training distributes at most 1,024 candidate indices across the resident current
note capture and consumes
at most 8 MiB of their exact body bytes, skipping oversized samples before
copying. Output is at most 8 KiB. A training job owns one captured generation;
failure/cancellation leaves the existing representation usable. Newly trained
bytes and referencing rows commit together. Mixed generations are supported.
Current-row reads load only the named dictionaries. Each read job reuses at most
four prepared dictionaries; reaching that working-set bound releases preparation
and later rows reprepare as needed. This bounds working memory while supporting
arbitrarily many dictionary generations. Old unused dictionaries impose no
startup scan. Explicit recoding attempts training at most once for a captured
view epoch/represented prefix per session; the attempt marker is ephemeral.

Dictionary rows are derived materialization metadata. Referenced missing,
misbound or invalid dictionary bytes require complete current-row reconstruction
from healthy retained history. Genuine shared database corruption, known
history loss and missing required private input keep their distinct recovery
outcomes. An exact private backup compares its raw captured dictionary/row cut
before normal destination recovery. Repair may rebuild both derived roles.

## Preparation and installation

Ordinary catch-up captures affected logical cells and compact context at an
exact connection/store/view prefix. Compression runs on the bounded worker.
Installation rechecks the complete starting view and target membership inside
the synchronous materialization transaction. Representation-only recoding also
checks the original physical rows so equal-prefix replacements cannot install
stale layouts. It changes no history, settings, pending work or user action.
Dictionary reclamation is deferred; retaining unused dictionaries is safe.

The durable history-verification request spans capture, worker preparation and
installation. A failed installation retains its replay obligation. Cancellation
of a caller leaves already-admitted required history/materialization owned until
settlement; optional recoding checks cancellation before installation. These
different ownership rules are exercised by the existing receive/recovery tests.

`recodeCurrentRows(basedOn:after:maximumRows:trainDictionary:)` reserves one
actor-owned job before suspension, accepts 1–256 rows per batch, and returns the
last processed birth as a cursor. The captured rows must still equal the exact
logical snapshot and physical input rows at installation. No automatic recoding
or training schedule is enabled.

## Initial capture and explicit maintenance

Returning open hands its actual checked current capture to the session. The
first `snapshot()` consumes that one-shot handoff and rechecks the owned store,
accepted prefix, full view/context and presentation generation. Stale captures
take the normal fresh capture path. Later publication still checks its live host
generation. This adds no maintained second current-state cache or public proof
constructor.

`compactPrivateStore(budget:)` is an explicit headless qualification API.
`VacuumOutcome` distinguishes completed, interrupted and skipped (required work,
store budget or space headroom). One closed actor state reserves preparation or
running work until settlement; required commits, receive/private-state writes,
backup, activation and close request cancellation before joining the database
lane. Caller task cancellation and `cancelOptionalMaintenance()` target the same
exact job. The C registry keeps its connection borrow alive until the owning
actor retires it. A unique, never-reused scalar identity lets cancellation run
while blocking SQL occupies the actor's executor. Only a running VACUUM receives
`sqlite3_interrupt`; pre-start cancellation is a flag and retired identities
leave subsequent SQL unaffected.

An almost-finished operation may complete after an interruption request, as
specified by [SQLite](https://sqlite.org/c3ref/interrupt.html). Both completion
and interrupted rollback must settle before resource release. Free-space checks
are advisory; write/sync failures retain their actual database outcomes. The
default explicit-work bounds are 256 MiB of live store pages and 64 MiB additional
headroom beyond twice the store size. They are qualification limits, not an
automatic maintenance policy or a latency guarantee. Production connections keep
the qualified 4-KiB cipher page geometry, `auto_vacuum=NONE`, encrypted pages and
memory-only temporary storage.

Alternative page geometry, physical hints and automatic compaction remain independent
qualification gates in the [4F plan](phase4-current-row-locality-maintenance-plan.md).
