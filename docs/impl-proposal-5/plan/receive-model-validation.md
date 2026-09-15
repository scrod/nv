# Receive resumption and rejection: bounded model validation

Date: 2026-09-16. Complements the [production-path tests](validation-resumption-results.md)
and [resumption contract](validation-resumption-plan.md). The models follow
[LocalStore](../LocalStore.md), DUR-01/WAIT-01/ROOT-01, and ADRs 0004/0010.
They cover two separate boundaries in the implemented ordinary-history Runtime.

## 1. Save interference, resumption and quiesce

[`ReceiveResumptionSafety`](../../tla/ReceiveResumptionSafety.tla) starts with one
owned, retained, valid receive whose prerequisites are available. A finite set of
local saves can interrupt its historical check. Receiving is already admitted;
repeated provider arrival is absent from this model.

| State | Purpose |
| --- | --- |
| Receive phase, checked prefix, two-attempt counter | Capture, validate, consume, restart, register/wake/recheck and finish |
| Save phase, admitted ID, accepted local IDs, pending handle | Separate admission, actual commit and completion delivery; a failed completion can leave a committed pending handle |
| Receive reservation and durable ready/accepted state | Preserve ownership through suspension, cancellation and shutdown |
| Quiesce phase and cancellation request | One shutdown attempt can wait, close, or return busy with a pending local handle |
| Audit fields | Record whether interruption, waiting and a second wait actually occurred; these fields never enable production actions |

`Commit.swift`'s completion clears active work and wakes registered continuations
in one actor turn. `WaitCheck` likewise checks the condition and registers in one
turn. Resumption is a later action, allowing a genuinely new save to start between
notification and the receiver's recheck. Validation consumption independently
rechecks its captured history prefix. A pending handle is distinct from an active
save; the former can persist while receive completes and quiesce returns busy.

The invariants require current validation at acceptance, a ready entry until
acceptance, receipt/completion backed by acceptance, and closing only after owned
work settles. Temporal checks require receive completion and quiesce settlement,
while preserving accepted local and received history.

Weak fairness applies only to runnable receive steps, active save work, completion
delivery and runnable quiesce checks. A sleeping continuation has no enabled receive
step: fairness cannot manufacture its missing wake-up. New saves, cancellation,
shutdown requests and user retry are optional. Finite admitted-save bounds represent
the requested quiet-after-editing scenario. The checks establish progress in those
finite configurations, not a latency bound or progress during endless interference.

Negative controls remove notifications, split condition checking from registration,
wait on pending handles, wait after work has already ended, consume a stale check,
close early, abandon cancellation/deferral, discard ready work, or wait for quiesce
while quiesce waits for receive. Witnesses require exhaustion of both attempts,
completion without a wait, a real new-save/re-wait order, pending-handle progress,
cancellation followed by close, and busy shutdown with received history accepted.

## 2. Rejection, waiting dependencies and recovery

[`ReceiveRejectionSafety`](../../tla/ReceiveRejectionSafety.tla) uses two fixtures:

- **Chain:** prerequisite → child → grandchild, plus unrelated valid input.
- **Multiple parents:** two prerequisites → child, plus unrelated valid input.

The first prerequisite is separately configured valid, invalid, or unsupported.
Both fixtures start with existing accepted history. Exact delivered bytes, ready
entries, waiting edges, rejection reasons, accepted membership and logical effect
counts are durable state. A separate transaction workspace expands rejection's
reason write, queue cleanup and commit; crash rolls back that workspace. Failure
after commit preserves the committed database even when completion is lost.

Inspection and parking are one SQL transaction. Acceptance wakes children on any
accepted prerequisite; a child rechecks every prerequisite before acceptance.
Delivery and a separately admitted parent can interleave at available writer turns.
This is the serial database protocol's input boundary, broader than the current
single public-receive reservation. The scheduling model above checks that reservation;
the models are complementary, rather than an `INSTANCE` composition or Swift refinement.

The checks require:

- exact input preservation and complete accounting as accepted, rejected, ready,
  or waiting;
- ready work whenever a retained, unclassified candidate has all prerequisites;
- complete accepted dependencies, retained accepted bytes, one logical application
  and preservation of existing history across rejection;
- rejection only from that candidate's own checked failure, with its queue cleanup
  committed together; descendants preserve their own bytes and waits;
- correct blocker diagnostics after queue settlement, with sound results during
  intermediate states;
- eventual acceptance of eligible supported input and eventual classification of
  a retained bad prerequisite, despite finite faults and optional repeated delivery.

Recovery progress explicitly assumes an actual retry/reopen request after storage
failure/crash, plus execution of runnable processing. It does **not** add automatic
I/O retry to the product. Missing prerequisite delivery and future software upgrades
remain optional. The valid-root companion exercises complete child/grandchild
acceptance; unsupported-root cases deliberately preserve blocked descendants.

Counters distinguish actual rejection-write failures from other failures, and
crash witnesses require cuts within the uncommitted rejection or after its commit.
The two-crash witness reaches both cuts and later accepts unrelated work. Another
witness requires two failures within rejection, followed by durable classification.
These counters and witnesses observe transitions; they never enable recovery.

## Findings and scope corrections

The first draft expected a grandchild to name a rejected root even when its
intermediate prerequisite had never arrived. The counterexample exposed a modeling
error: NV cannot traverse an undisclosed dependency list. The independent diagnostic
oracle now requires that intermediate evidence. Soundness remains unconditional;
complete reporting is required after relevant evidence is retained and work settles.
This follows the existing missing-data contract rather than changing product policy.

The resumption model's initial implication grouping left a successor unspecified;
TLC rejected it before qualification. The runner also needed to recognize this
TLC version's explicitly named temporal-failure diagnostic. Neither exploratory
failure counted as a passing control. No production behavior or safety requirement
was weakened, and no new implementation defect has been established by these runs.

## Execution and reproduction

```sh
python3 docs/tla/check-receive-models.py \
  --java '/Applications/Wolfram Engine.app/Contents/Resources/Wolfram Player.app/Contents/SystemFiles/Java/MacOSX-ARM64/bin/java' \
  --jar /tmp/nv-sqlite-contract.dyK74N/tla2tools.jar
```

`--only resumption` or `--only rejection` selects a family. The default runs them
in that order. Same-named checked `.cfg` files describe a representative safe run;
the runner records every effective configuration, model hash, TLC log, state count
and outcome in a fresh temporary directory. Timeout, parsing error, unspecified
successor or an unrelated assertion failure never counts as a successful control.
Each temporal negative control selects exactly its intended property.

All **47 expected outcomes** completed with the bundled Wolfram Java runtime and
TLC from `/tmp/nv-sqlite-contract.dyK74N/tla2tools.jar`:

| Family | Exhaustive safe configurations | Targeted mutation counterexamples | Reachability witnesses |
| --- | ---: | ---: | ---: |
| Resumption/quiesce | 3 | 11 | 6 |
| Rejection/recovery | 9 | 11 | 7 |

Resumption bounds of zero, two and three admitted saves explored 30, 1,232 and
3,252 states respectively. Rejection's no-fault baseline explored 701 states;
the largest configuration (invalid-root chain, two crashes and two storage
failures) explored **30,353 states in 6.61 seconds**. Other safe rejection
configurations explored 4,367–16,705 states. Runtime measurements describe this
development Mac, not a platform guarantee.

Final artifacts: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-receive-tla-nv3u1ghq/`.
The root `results.json` records exact model hashes and each effective outcome.
Earlier failed drafts remain in their own temporary artifact directories.

## Evidence boundaries

These are exhaustive finite-state checks, using no state/depth pruning, `VIEW`,
symmetry or sampled simulation. SANY parsing is part of every TLC invocation.
Progress assumptions are explicit and separate from safety. Negative controls fail
the named assertion; witnesses establish reachability, not universal progress.

SQL atomicity, authenticated exact-object identity and truthful semantic validity
are inputs. Cryptography, arbitrary graphs, arbitrary numbers of saves/faults,
physical power loss, actual executor scheduling, paged diagnostic traversal,
future-validator migration, text reduction and application/provider integration
remain outside these models. The production fault/concurrency tests provide their
separate implementation evidence. Existing SQLite models retain their broader
materialization/import checks and are unchanged. Failed damage-marker persistence
remains the separately proposed third investigation.
