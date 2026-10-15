# Retired preserved repository replacement

On 2026-10-14 the user replaced this exploratory policy with stop-and-Save-As for
occupied damaged entries. Automatic missing-entry repair remains active in
`docs/tla/RepositoryRepairSafety.tla`; private selected-store activation and
ordinary note-saving replacement keep their distinct contracts.

This model and its former 28 checks explored durable reminders, exact displacement,
barriers, reconciliation, restart and repeated failures. The prior run passed
(`/tmp/nv-p56-preserved-model-final.log`, largest scenario 222 states). It assumed
the native preservation primitive and normal intake; it established neither
production refinement nor physical power-loss durability. No production backend
or durable replacement record was implemented. It is excluded from active runners.

The five-case Foundation capability probe remains active experimental evidence:
`python3 tools/test-storage-repair-replacement-capability.py`. Its measured
preservation does not meet an atomic no-write-on-mismatch requirement, motivating
the simpler policy. Its results remain in the P5.6 qualification ledger.
