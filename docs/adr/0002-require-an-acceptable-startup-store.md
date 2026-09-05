# Require a complete local startup view, not a provider-current database

Status: accepted.

Returning startup validates the private store's ownership, association, profile and key, then drains indexed ready work, catches up the private current materialization, and constructs complete current notes and compact authoring frontiers from current rows. The [fast-start contract](../impl-proposal-5/LocalStore.md) requires no mandatory full-history read on a healthy returning launch; bootstrap or invalid-materialization recovery may require it. The fuller history/candidate UI index may load later. It need not wait for the provider or materialize every plaintext file. Invalid derived rows require reconstruction, not permission to reset settings or omit durable work. Missing known history or private association requires repair/explicit recovery rather than editable emptiness.

A fresh device may preview a complete authenticated snapshot read-only after all its pages validate, but editing waits for its durable dependency closure and the complete genesis/import commitment. This is a narrowly scoped bootstrap preview, not an editability trap. A returning complete store ordinarily edits from local history despite generic provider unavailability. Work Offline is a distinct choice only when positively disclosed newer/required provider bytes remain unmaterialized or unreadable; it grants no provider-root access without root ownership. This wait applies only to evidence already disclosed during startup. Do not wait for provider discovery to decide whether to offer it, or suspend an already editable session on later disclosure. Eviction of an exact provider copy already retained locally is no missing-evidence gate.

Preexisting folders require explicit creation; empty listings and ENOENT prove no remote absence. Concurrent unrelated bootstraps require selection. Rebuild from Note Files is detached, stable-current-file salvage into a new collection, with explicit decoder/target/conversion choices and verified complete output. Source history is preserved. No newest-snapshot election or Spotlight gate is permitted.

Normative requirements: AUTH-01, START-01, CKPT-01, WAIT-01.
