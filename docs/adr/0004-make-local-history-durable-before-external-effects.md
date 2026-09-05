# Make local history durable before external effects

Status: accepted.

The local segment-and-parent barrier precedes durable acknowledgment, publication eligibility, external-editor completion and the original physical deletion. Note operations and their action metadata recover together. A RAM-only parent makes a durable child unusable after crash; therefore closure is part of the barrier, not a later transport optimization.

Plaintext projection and provider publication are independent follow-on obligations. Their delay cannot hold the local sealer hostage or invalidate already durable notes. There is no file-first shared-checkpoint close ordering: derived materialization may lag, and no derived view retires history. Exact note-file installation remains an additional gate before Apple conflict disposition.

Existing-file projections retain rooted expected-snapshot safe replacement and preservation of displaced work. Immutable provider objects use exclusive creation and exact verification. Privately, one [SQLite acceptance transaction](../impl-proposal-5/LocalStore.md) retains exact bytes, complete accepted membership, pin advancement and dependency wakeups together. A committed operation whose callback was lost is recovered by exact identity, not by asking whether its note is still live. Current materialization may lag; its failure does not retract committed history. SQLite atomicity does not supply filesystem authority or prove reducer correctness.

Normative requirements: DUR-01, DELETE-01, REC-01, CKPT-01.
