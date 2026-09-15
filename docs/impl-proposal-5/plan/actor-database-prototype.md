# Database actor / asynchronous history lookup experiment

Status: initial isolated feasibility experiment, followed by the adopted
[production actor implementation](actor-database-adoption.md). Results below
describe the original probe rather than qualification of the later conversion.

The design preference is to consider actor ownership when it makes a mutable-state
boundary both simpler and safer. Dispatch still supplies blocking-I/O execution;
an actor can add compiler-enforced ownership over that execution resource.

## Shape exercised

`tools/prototypes/ActorDatabaseProbe.swift` contains a small `SerialExecutor`, an
actor owning a non-Sendable SQLCipher connection, and an asynchronous synthetic
ancestry traversal. Each read awaits one synchronous database method. Its local
traversal stack survives suspension naturally. Each append checks its expected
generation and completes its SQL transaction in one synchronous actor turn.
The actor owns connection creation and explicit close. The experiment introduces
zero unchecked Sendable conformances, semaphores, synchronous cross-queue calls,
production scheduling fields or format changes.

The synthetic schema is a linear parent chain. It uses real keyed SQLCipher,
WAL/FULL synchronization and indexed reads, with queue preconditions at the C
calls. Its fixed key and SQL literals belong exclusively to synthetic test data.
This exercises the ownership/suspension mechanism, rather than the production
schema, complete ordinary-action validator or encryption/key lifecycle.

## Checks and scope

Run `python3 tools/prototypes/test-actor-database.py` after building the repository's
pinned SQLCipher dependency. `NV_SQLCIPHER_PREFIX` can select its installation.
The runner preserves binaries, databases and logs in a fresh temporary directory.

- Compile in Swift 6 mode with complete concurrency checking, debug and optimized.
- Independently expect all 64 original ancestors.
- Pause after the first read; complete a local save before allowing traversal to
  continue. The next read must reject the stale generation.
- Complete a fresh traversal; insert another save before acceptance. The final
  generation fence must reject the old view and leave the row count unchanged.
- Complete 32 concurrent append callers; check exact count and the entire parent
  chain after closing and reopening the encrypted database.
- Reject access after close.
- Compile intentional cross-actor state mutation and connection-escape clients;
  require rejection at the marked source line. These use object compilation so
  later concurrency diagnostics participate, alongside the passing executable.

The completed local run passed both executable configurations and both marked
compiler-rejection checks with Swift 6.4 on arm64 macOS 26.6.2, targeting 11.5.
Both resulting database headers were encrypted. Artifacts:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-actor-prototype-8qu19xa2/`.
The connection-escape diagnostic appears during object compilation; a
`-typecheck`-only run did not diagnose that deliberate misuse, so the runner
requires the fuller compile pass. This is a harness qualification detail.

Actual
macOS 11 execution, Linux execution and Swift 6.1 compilation of this experiment
remain unqualified. Prior ordinary-actor platform runs do not qualify a custom
executor. `UnownedJob` and an explicit `asUnownedSerialExecutor()` implementation
allow the older deployment declaration; the SDK's default implementation of that
method requires macOS 14. Actual older-runtime execution remains a separate gate.

## Complexity assessment and stopping point

The executor and asynchronous read pattern are compact enough to justify further
consideration. The experiment stops short of converting the production validator:

1. `OrdinaryHistoryV1` and `ChangesPayloadV1.checkExternalReferences` have nested
   synchronous lookup helpers. Async conversion reaches those helpers and several
   `map`, `allSatisfy` and nil-coalescing expressions, which need explicit loops or
   branches. Keep ordinary action rules shared with current-basis validation.
2. Compare an async implementation of the real validator against the existing
   implementation using the same valid and near-valid fixtures before replacement.
   The synthetic traversal alone cannot establish semantic equivalence.
3. Qualify connection disposal on partial open, abandoned owners, cancellation and
   shutdown with admitted work. Explicit close/reopen in this experiment covers
   only the simple lifetime path.
4. Retain the existing resumption, final-generation, failure and crash tests, and
   remeasure per-record lookup overhead and local-save progress. Actor isolation
   preserves exclusive access; admission, retry and acceptance remain protocol
   responsibilities.

Thus the small prototype suggests clearer ownership with little executor plumbing,
but does not establish a net reduction in complete production code complexity.
Stop a migration if it grows an elaborate synchronous/async bridge merely to retain
the existing callback API. No production or modeled transition changed, so this
experiment requires no TLA+ rerun or application build.
