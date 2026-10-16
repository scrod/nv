# P6.1 — Frozen output and bounded byte ownership

This implements the private input ownership beneath the specified serialized
per-note projection transition. An intended output can change while an earlier
transition is unfinished. Its exact bytes and original source remain owned until
source accounting and settlement can complete. A retained transition is passive
recovery state; fresh rooted evidence still governs every physical operation.

## Records and consumers

The single current, unreleased `ProjectionObservationsV1` layout appends an
optional `IntendedProjectionV1` frozen record. Accepted, intended, intended source,
frozen output and frozen source form its complete byte-owner set. One output
generation has one exact encoding/binding across all those owners. A frozen
generation is greater than accepted and at most intended; equal frozen/intended
generations require identical records. A later intention preserves the frozen
record exactly. One slot follows the existing policy of serializing a note's
physical transition through source accounting.

`freezeProjectionIntent(observations:)` accepts only the store-issued immutable
capture. Its synchronous owner transaction checks store/session, current private
generation/value, private scope and live association before retaining the exact
intended record. Repeating against the current same frozen/intended state is
idempotent. A different already-frozen transition returns `busy`; stale captures
must be reread. No source bytes, note history, current values or installation
receipts change. Restart recovers the record without recovering physical authority.

The ordinary and sibling-module compiler probes reject passing a decoded passive
record in place of the store-issued capture and mutating a frozen property.
Existing capture constructor restrictions remain intact. There is deliberately
no public method accepting a passive record as proof that a file was installed.

## Captured bytes and cleanup

Captured chunk keys include birth and digest. This changes the current unreleased
private layout directly. Equal outputs within a note share chunks; separate notes
have separate owners and copies. The trade-off is possible cross-note duplicate
bytes in exchange for bounded local cleanup without a new reference-count index
or collection-wide scan.

`retainProjectionIntent` atomically installs new chunks, replaces the guarded
observation and removes old captured digest ranges absent from every new owner.
It examines at most the old and new per-note owner sets. The transaction's failure
or ambiguous completion leaves either the old complete owner/bytes or the new
complete owner/bytes. Cleanup failure rolls back the whole switch. A stale reader
whose chunks were legitimately released receives the stale-capture outcome;
missing bytes under an unchanged owner remain integrity failure. Whole-byte
digest and final owner checks remain mandatory.

Pending external previews and reservations continue to own their separate
`pending_payloads` data. They do not borrow projection chunks. The
[settlement record mapping](14-settlement-record-contract.md) describes the exact
owner transfer. Its future rooted consumer must atomically transfer any still-needed
projection ownership before clearing a frozen slot. Accepted-transition
publication, pending receipt links and physical evidence consumption retain their
P6.4 gates; a codec or frozen record alone does not establish those effects.

## Qualification

- Independent Python framing: absent, empty metadata, unfrozen, frozen and newer
  intended records; Swift exact round trips, every truncated prefix, wrong scope,
  unsupported tags, incompatible output generations and source ownership.
- Production A accepted → B frozen → C intended → D intended: preserve A/B/D,
  release only C, then Delete, copy, restart and read exact old bytes. Passive A is
  explicitly seeded; the test establishes retention, not physical installation.
- Equal bytes on different notes; same-note digest reuse; repeated cleanup and
  freeze-write failures; unchanged prior owner and chunk inventory after rollback.
- Process termination before/after commit, ENOSPC and EIO for both intent switching
  and freezing. Independent parent checks private SQL bytes, generations and notes;
  the recovering child receives only ordinary surviving selection/unlock inputs.
- Changed private state during reads, wrong store/session/association, repeated
  same-state freezing and exclusion of a second unfinished transition.
- Mutation controls discard the frozen owner, disregard its chunk ownership or
  omit its durable write. Each must fail its designated assertion with a passing
  companion. The existing final-read fence control retains a frozen input so its
  failure reaches the intended final check even when obsolete bytes are collected.

The existing `PendingReferenceSafety` frozen/latest and cleanup obligations and
`ProjectionTransitionSafety` serialized A/B/C obligations are unchanged. This is
an executable storage mapping, not a claim that the models prove SQLite, codecs
or physical installation. Retain completed model qualification and unchanged
native encoding results; rerun affected Swift, fixture, process and compiler work.
