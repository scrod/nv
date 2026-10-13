# P5.6 — Transparent repair, safe replacement and repository copy

Status: planned. Dependency: [P5.5](05-startup-and-root-reassociation.md).
Replacement primitive experiments may start after P5.2; caller qualification
requires the ownership, transport and health boundaries above.

Testing: [repair/copy/cleanup/privacy families](../phase5-provider-root-testing-plan.md#repair-preservation-and-confidentiality),
[replacement caller gates](../phase5-provider-root-testing-plan.md#42-foundation-replacement-and-caller-gates)
and S4. Follow [ADR-0016](../../../adr/0016-repair-from-validated-immutable-copies.md),
the [repair contract](../../../iCloud-Drive-Support-Spec.md#repository-and-private-store-damage-and-repair)
and [Foundation migration](../../../Foundation-Safe-Replacement-Migration.md).

## Implementation

1. Connect the common health classifier to source acquisition. Capture exact
   compatible descriptors/objects from private history, provider files and an
   explicitly selected backup. Validate identities and complete required closure;
   union compatible evidence rather than preferring timestamps or subtracting
   absent entries. Preserve damaged/foreign sources and all unique private work.
2. For positively same-root local `NV Data` omission with complete usable private
   closure and no qualifying unread provider evidence, repair automatically.
   Reobserve under ownership/coordination, exclusively create directories and
   install exact retained objects/descriptors through P5.2. Interrupted add-only
   output is retryable; full repair means the complete captured known closure.
3. For owned damaged entries, build/verify an unattached replacement, preserve
   displaced evidence and consume only the captured still-applicable generation.
   Stop/reclassify on changed authority or a competing occupant. Preserve/union
   a compatible winner; preserve/report foreign, symlinked or incompatible input.
   There is no Restore NV Data control or automatically broadened permission.
4. If private history/state also needs repair, rebuild it first. Preserve original
   SQLCipher database/journals, salvage on a working copy, validate a compatible
   history union and retain valid settings, pending latest/frozen input, operation
   links and verification obligations. Use existing fresh-sibling repair, reopen,
   retained-history pin and selected-store activation before provider repair.
5. Implement a narrow Darwin regular-file replacement backend for its applicable
   callers: same-volume replacement staging, actual accessor URL, preserved backup,
   explicit metadata policy and rooted final/displaced readback. Classify no-write
   failure versus installation needing reconciliation. Keep private SQLite
   transactions/activation, strict new-object installation and populated-directory
   repair as their own qualified intents.
6. Qualify populated-directory repair separately. Validate the unattached complete
   replacement, preservation and namespace/barrier behavior with competing entries.
   A precheck followed by replacement is not an atomic comparison against arbitrary
   external writers. If the helper cannot meet a caller's stated race contract,
   preserve inputs/report the capability gap; never relabel it as successful CAS.
7. Connect repository Save As to existing repository-only preservation and saved-work
   copy paths. Preserve exact available history and identities, report placeholders,
   unknown entries, changed sources and dependency holes. Application Support is
   not a prerequisite for repository-only copy. Complete saved-work copy additionally
   uses the captured local durable objects; it cannot claim to include absent RAM
   edits. Current-state recovery export remains a separately labeled fresh-genesis
   operation. Keep pending live work until separately saved/exported.
8. A copy-only request leaves the active root unchanged. A requested switch verifies
   the destination, establishes fresh physical ownership/private association/writer
   context, and uses the lifecycle handoff from P5.5. Preserve old sources/credentials
   through ambiguous completion. Phase 7 wires the final application transition;
   Phase 6 qualifies plaintext projection admission and source-removal consumers.

Reuse [PrivateRepair](../../../../NVStorage/Sources/NVStorageRuntime/PrivateRepair.swift),
[StoreSelection](../../../../NVStorage/Sources/NVStorageRuntime/StoreSelection.swift)
and [CollectionCopies](../../../../NVStorage/Sources/NVStorageRuntime/CollectionCopies.swift).
Keep existing qualified fresh-destination copy semantics distinct from strict
shared-root publication. Unknown source files are preserved/reported by copy;
they do not become note history without the later projection admission boundary.

## State and language boundaries

Carry exact source context/observations, captured inventory/completeness and
ownership through repair/copy. Restricted evidence distinguishes a verified
repair union, preserved displacement, verified replacement and committed activation.
Their actual consumers recheck context after suspension and before effect/cutover.

Reuse the existing retained-history pin, private pending records and selected-store
record; invent no second recovery store or permanent physical-delete permission.
Old copied receipts remain observations requiring fresh physical validation.
Complete/partial/unavailable copy outcomes are exhaustive and separately visible.

## Tests

- Compose root identity, entry kind, access, exact bytes, closure, preservation and
  writability across root/`NV Data`/subdirectory/object/private-store levels. Include
  omission, corruption, wrong kind, unreadability, read-only/full destinations and
  preservation failures. Check actual automatic repair/status decisions.
- Run S4 with complementary sources, unpublished history and unique private state;
  fail around preservation, pin, activation, reopen/diagnosis and fail again during
  recovery. Independently inspect sources, siblings, displaced artifacts and final
  known closure. Missing evidence everywhere yields incomplete recovery.
- Race compatible/foreign occupants and root changes against every installation
  intent. Sweep Foundation replacement mechanisms, metadata and displaced bytes
  through actual callers; include old helper weak branches as negative controls.
  Do not qualify populated-directory replacement from a regular-file result.
- Copy without a private store, with placeholders/unknown entries/holes, and with
  source changes. Exec independent destination readers. Pair saved-work copy with
  local failure/pending RAM input and explicitly labeled current-state export.
- Challenge abandoned stages, replaced cleanup names, unrelated stage-like files,
  delayed completions and cancellation. Preserve every foreign/recovery/accepted
  artifact; report uncertain cleanup instead of deleting by prefix.
- Audit actual stage/displacement/copy/export/log sinks under both profiles, including
  wrong credentials, rejected input and Keychain unavailable for password-free use.

Add restricted-construction/context probes and targeted mutations for incomplete
repair activation, overwritten race winners, dropped unique private input,
false copy completeness, source cleanup and leaked plaintext. Run applicable
image/OS/process/memory checks; use native integration tests and `build.sh` when
shared app helpers change. Later projection/UI caller qualification stays explicit.

## Exit gate

Locally decidable same-root repair is transparent and source-preserving. Private
repair activation retains all available unique work and its complete pin before
provider repair. Repository copy and current-state export report their distinct
coverage honestly. Qualified effect consumers pass crash/race/context witnesses;
unsupported replacement capabilities remain explicit, with no contract weakening.
