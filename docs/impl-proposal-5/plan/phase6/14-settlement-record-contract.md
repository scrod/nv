# P6.1 — Exact pending settlement and projection-owner transfer records

This completes the passive private record mapping required by P6.1. P6.2/P6.4
still issue and consume fresh rooted installation/source-accounting evidence;
P6.5 integrates provisional relationship claims with pending-file admission.
A decoded record describes an earlier observation. It supplies neither current
file permission nor replayable user consent.

## Two distinct settlement outcomes

`PendingSettlementV1` retains the complete admitted reservation after its preview
bytes become releasable. Its outcome is an exhaustive sum:

- **Consumed input:** the existing pending completion path has checked the exact
  committed operation or neutral Current and recorded the host observation.
  This settles repeated import of that input, including after a later Delete.
  It does not advance accepted projection state.
- **Completed projection:** an exact `ProjectionSettlementV1` records the output,
  physical/raw-metadata observation, relationship generation and completed source
  accounting. The future rooted consumer must establish these facts and install
  the receipt and owner transfer in the same guarded transaction. P6.1 implements
  its passive codec and transfer calculation, not a public receipt issuer.

These are different semantic cases within the single current development format,
not compatibility branches. Both collection profiles support consumed-input
records. Completed plaintext projections require the plaintext-files profile.

## Current canonical layouts

All integers are big-endian. Nested blobs have u32 lengths; optional records use
u8 0/1 with a length-prefixed value when present. The 64-MiB private-record ceiling,
strict trailing/truncation checks and existing canonical identifier rules apply.

`ProjectionSettlementV1`:

1. `NVPSL1\r\n`, u16(1), private scope (64), association ID (16).
2. Positive relationship generation (u64, at most Int64.max).
3. Complete frozen intended transition blob, complete accepted observation blob.
4. Optional passive source-accounting observation, present exactly when the
   transition has an earlier source. Same-item replacement also accounts for its
   earlier source; the platform observation describes the actual outcome.

The accepted output equals the frozen output exactly, including encoding,
generation, complete history binding and actual filename/digest. The scope's
collection matches that output. Bindings already enforce source birth/collection.

`PendingSettlementV1`:

1. `NVPST1\r\n`, u16(1), captured input scope (64), pending item ID (16).
2. Length-prefixed complete `PendingReservationV1`, including its decision, frozen
   input, birth and exact operation/nonce/action/result or neutral-state digests.
3. Outcome u8: 1 = length-prefixed passive consumed observation; 2 =
   length-prefixed complete projection settlement.
4. Optional subsequent snapshot: u8 0/1, then its 16-byte ID when present.

The subsequent ID differs from the settled snapshot. It records work outstanding
at completion; the pending item's latest/frozen references continue to own actual
preview bytes as that work changes. Completed historical records do not pin every
superseded preview forever. Projection and input scopes may name different local
stores after a verified sibling repair, but must share the collection; the runtime
validates each using the existing captured-scope/repair-source mechanism.

## Existing SQL mapping and ownership

Use the existing `pending_settlements` row, with `observation_codec = 1` and the
complete new record in `observation`. Existing item/snapshot/reservation/operation/
birth indexes and the SHA-256 of the reservation remain derivable checks. The
owned reader verifies all of them against the encoded record and validates scope.
Unknown codec/version yields unsupported; malformed bytes or contradictory row
identity yields integrity; an unrecognized captured store yields wrong context.
No table, sidecar, live validation flag or cache is added.

The existing consumed-input writer stores this complete record, removes its
reservation and advances the generation-checked pending item in one transaction.
It clears latest only when latest is that input; newer previews remain. Optional
payload cleanup follows the existing owner query. The record preserves the full
decision even after that cleanup. Exceptional complete backup/repair validates
settlement framing/index/scope; healthy startup adds no history-wide receipt scan.
Receipt decoding is passive, while reuse for new effects still requires the
appropriate current history/physical consumer checks.

`ProjectionSettlementV1.transferringOwners(in:)` is a pure description calculation.
It requires exact scope, association, birth, frozen transition and prior accepted
source. For A accepted → B frozen → C intended, it produces B accepted, C intended
with B as source, and an empty frozen slot. If B is also latest, the intention
clears. A repeated/stale B cannot regress accepted state. Actual transaction
publication must additionally check the live relationship generation, note
liveness, root and source-accounting evidence. It must commit receipt, new owners
and eligible chunk release together before dropping any pending link. Those
physical effects remain P6.4.

## Validation scope

Independent Python fixtures cover consumed, neutral and projection records;
Swift tests check exact fields/bytes, truncations, profile restrictions, source
accounting and owner-transfer races. Production tests cover repeated rollback,
retained exact decisions, newer previews, row-field corruption, unsupported codec,
wrong store, reopen and exceptional private-state validation. Child-process fault
schedules independently decode the new SQL record and verify retained history.
Ordinary and sibling-module construction probes restrict `PendingSettlement` to
its owned reader; passive Core values remain constructible descriptions.

These tests qualify record encoding and consumed-input atomicity. They do not
claim a physical replacement or deletion occurred. See the
[completion ledger](06-completion-ledger.md) and [qualification report](14-settlement-record-validation.md) for results.
